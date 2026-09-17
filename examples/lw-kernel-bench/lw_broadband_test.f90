! ------------------------------------------------------------------------------------------------
! Reproducer for the in-model GPU crash: the do_broadband=.TRUE. longwave path.
!
! What every prior standalone test missed:
!   lw_solver_bench.F90 and lw_solver_cwrap_ifort.f90 both call with do_broadband = 0 (FALSE) and
!   pass plain CONTIGUOUS arrays. But GEOS (GEOS_IrradGridComp.F90) always uses
!   type(ty_fluxes_broadband) -> the front-end sets do_broadband = .TRUE., which:
!     (a) runs a DIFFERENT on-device path (broadband reduction) and a DIFFERENT copyout
!         (broadband_up/broadband_dn instead of the g-point flux_up/flux_dn), and
!     (b) receives, as broadband_up/broadband_dn/broadband_upJac, GEOS pointers to NON-CONTIGUOUS
!         array sections: fluxes%flux_up => flux_up_clrnoa(colS:colE,:).
!   Neither (a) nor (b) has ever been exercised by a standalone test or by the earlier memcheck run.
!
! This program calls the SAME C entry the model calls -- rte_lw_solver_noscat_gpu (the shim in
! librtekernels.so) -- with do_broadband=1, do_Jacobians=1, at model dims, in two modes:
!   mode 0 : CONTIGUOUS broadband targets            (isolates the broadband device path alone)
!   mode 1 : NON-CONTIGUOUS section targets (colS:colE,:) surrounded by a sentinel guard band,
!            mimicking GEOS. After the call it counts how many guard elements OUTSIDE the intended
!            section were overwritten -- a nonzero count is an out-of-section host write.
!
! Run under compute-sanitizer memcheck (see run_broadband_test.sbatch): memcheck catches an
! out-of-bounds DEVICE write in the reduction; the sentinel guard catches a bad device->host
! copyback into the non-contiguous target. Either one localizes the corruption.
!
! Build: same as the cwrap test (ifort caller, link librtekernels.so).
! Usage: ./lw_broadband  ncol nlay ngpt nmus mode
! ------------------------------------------------------------------------------------------------
program lw_broadband_test
  use, intrinsic :: iso_c_binding, only: c_int, c_double
  implicit none
  integer, parameter :: wp = c_double
  real(wp), parameter :: SENT = -987654.0_wp   ! guard-band sentinel

  interface
    subroutine rte_lw_solver_noscat_gpu(ncol, nlay, ngpt, top_at_1, nmus, Ds, weights,       &
                                        tau, lay_source, lev_source, sfc_emis, sfc_src,      &
                                        inc_flux, flux_up, flux_dn,                          &
                                        do_broadband, broadband_up, broadband_dn,            &
                                        do_Jacobians, sfc_srcJac, broadband_upJac, flux_upJac, &
                                        do_rescaling, ssa, g) bind(C, name="rte_lw_solver_noscat_gpu")
      import :: c_int, c_double
      integer(c_int), intent(in)    :: ncol, nlay, ngpt
      integer(c_int), intent(in)    :: top_at_1
      integer(c_int), intent(in)    :: nmus
      real(c_double), intent(in)    :: Ds(ncol,ngpt,nmus)
      real(c_double), intent(in)    :: weights(nmus)
      real(c_double), intent(in)    :: tau(ncol,nlay,ngpt)
      real(c_double), intent(in)    :: lay_source(ncol,nlay,ngpt)
      real(c_double), intent(in)    :: lev_source(ncol,nlay+1,ngpt)
      real(c_double), intent(in)    :: sfc_emis(ncol,ngpt)
      real(c_double), intent(in)    :: sfc_src(ncol,ngpt)
      real(c_double), intent(in)    :: inc_flux(ncol,ngpt)
      real(c_double), intent(out)   :: flux_up(ncol,nlay+1,ngpt)
      real(c_double), intent(out)   :: flux_dn(ncol,nlay+1,ngpt)
      integer(c_int), intent(in)    :: do_broadband
      real(c_double), intent(inout) :: broadband_up(ncol,nlay+1)
      real(c_double), intent(inout) :: broadband_dn(ncol,nlay+1)
      integer(c_int), intent(in)    :: do_Jacobians
      real(c_double), intent(in)    :: sfc_srcJac(ncol,ngpt)
      real(c_double), intent(out)   :: broadband_upJac(ncol,nlay+1)
      real(c_double), intent(out)   :: flux_upJac(ncol,nlay+1,ngpt)
      integer(c_int), intent(in)    :: do_rescaling
      real(c_double), intent(in)    :: ssa(ncol,nlay,ngpt)
      real(c_double), intent(in)    :: g(ncol,nlay,ngpt)
    end subroutine rte_lw_solver_noscat_gpu
  end interface

  integer(c_int) :: ncol, nlay, ngpt, nmus
  integer(c_int) :: do_rescaling
  integer :: nargs, mode, cs, ce, ntot, nlev, bad_up, bad_dn, bad_jac
  integer :: icol, ilay, igpt
  character(len=32) :: arg

  real(wp), allocatable :: Ds(:,:,:), weights(:)
  real(wp), allocatable :: tau(:,:,:), lay_source(:,:,:), lev_source(:,:,:)
  real(wp), allocatable :: sfc_emis(:,:), sfc_src(:,:), inc_flux(:,:)
  real(wp), allocatable :: flux_up(:,:,:), flux_dn(:,:,:)
  real(wp), allocatable :: sfc_srcJac(:,:), flux_upJac(:,:,:)
  real(wp), allocatable :: ssa(:,:,:), g(:,:,:)
  ! broadband targets: contiguous plain arrays (mode 0) OR pointer sections of a guarded backing (mode 1)
  real(wp), allocatable, target :: big_up(:,:), big_dn(:,:), big_jac(:,:)
  real(wp), pointer     :: bb_up(:,:), bb_dn(:,:), bb_jac(:,:)

  ! -------- CLI --------
  ! 6th arg do_rescaling: GEOS passes 1 (ty_optical_props_2str with use_2stream=.false. -> the
  ! "no-scattering with rescaling" branch, mo_rte_lw.F90:461-472). do_rescaling=1 reads ssa/g on the
  ! device (kernel line 157-158) and runs lw_transport_1rescl (kernel line 209). Both are untested.
  ncol = 2048_c_int ; nlay = 91_c_int ; ngpt = 128_c_int ; nmus = 1_c_int ; mode = 1
  do_rescaling = 0_c_int
  nargs = command_argument_count()
  if (nargs >= 1) then ; call get_command_argument(1, arg) ; read(arg,*) ncol ; end if
  if (nargs >= 2) then ; call get_command_argument(2, arg) ; read(arg,*) nlay ; end if
  if (nargs >= 3) then ; call get_command_argument(3, arg) ; read(arg,*) ngpt ; end if
  if (nargs >= 4) then ; call get_command_argument(4, arg) ; read(arg,*) nmus ; end if
  if (nargs >= 5) then ; call get_command_argument(5, arg) ; read(arg,*) mode ; end if
  if (nargs >= 6) then ; call get_command_argument(6, arg) ; read(arg,*) do_rescaling ; end if
  nlev = nlay + 1

  ! -------- inputs (identical synthetic values to the bench/cwrap) --------
  allocate(Ds(ncol,ngpt,nmus), weights(nmus))
  allocate(tau(ncol,nlay,ngpt), lay_source(ncol,nlay,ngpt), lev_source(ncol,nlev,ngpt))
  allocate(sfc_emis(ncol,ngpt), sfc_src(ncol,ngpt), inc_flux(ncol,ngpt))
  allocate(flux_up(ncol,nlev,ngpt), flux_dn(ncol,nlev,ngpt))
  allocate(sfc_srcJac(ncol,ngpt), flux_upJac(ncol,nlev,ngpt))
  allocate(ssa(ncol,nlay,ngpt), g(ncol,nlay,ngpt))
  Ds = 1.66_wp ; weights = 0.5_wp
  sfc_emis = 0.98_wp ; sfc_src = 5.0_wp
  inc_flux = 0.0_wp ; sfc_srcJac = 0.05_wp
  flux_up = 0.0_wp ; flux_dn = 0.0_wp ; flux_upJac = 0.0_wp
  ! SPATIALLY-VARYING, physically-plausible inputs. The clean bench used UNIFORM tau=0.1,
  ! ssa=0.5, g=0.6 -- the model feeds the device rescaling path non-uniform optical properties
  ! that span the physical box. A device-codegen miscompute can be value-range sensitive, so
  ! sweep the box deterministically (index hashes, reproducible): tau in [1e-3, ~12],
  ! ssa in [0, 0.7], g in [0, 0.85] -- never 1.0 (kernel comment: g=ssa=1 gives NaN).
  do igpt = 1, ngpt
    do ilay = 1, nlay
      do icol = 1, ncol
        tau(icol,ilay,igpt)        = 1.0e-3_wp + 12.0_wp * &
             real(mod(icol*7 + ilay*13 + igpt*3, 100), wp) / 100.0_wp
        lay_source(icol,ilay,igpt) = 1.0_wp + 4.0_wp * real(ilay, wp) / real(nlay, wp)
      end do
    end do
  end do
  do igpt = 1, ngpt
    do ilay = 1, nlev
      do icol = 1, ncol
        lev_source(icol,ilay,igpt) = 1.0_wp + 4.0_wp * real(ilay, wp) / real(nlev, wp)
      end do
    end do
  end do
  ! ssa/g are read on the device only when do_rescaling=1. With do_rescaling=0 they are unused.
  if (do_rescaling == 1_c_int) then
    do igpt = 1, ngpt
      do ilay = 1, nlay
        do icol = 1, ncol
          ssa(icol,ilay,igpt) = 0.70_wp * real(mod(icol*3 + ilay*5  + igpt*2, 100), wp) / 100.0_wp
          g  (icol,ilay,igpt) = 0.85_wp * real(mod(icol*2 + ilay*11 + igpt*7, 100), wp) / 100.0_wp
        end do
      end do
    end do
  else
    ssa = 0.0_wp ; g = 0.0_wp
  end if

  ! -------- broadband targets --------
  if (mode == 1) then
    ! GEOS-like: a wide backing array, take the MIDDLE column-chunk as the (non-contiguous) target,
    ! fill the rest with a sentinel so any out-of-section write is visible.
    ntot = 3*ncol ; cs = ncol + 1 ; ce = 2*ncol
    allocate(big_up(ntot,nlev), big_dn(ntot,nlev), big_jac(ntot,nlev))
    big_up = SENT ; big_dn = SENT ; big_jac = SENT
    bb_up  => big_up (cs:ce,:)
    bb_dn  => big_dn (cs:ce,:)
    bb_jac => big_jac(cs:ce,:)
    write(*,'(a)') '# mode 1: NON-CONTIGUOUS section targets (GEOS-like colS:colE slice)'
  else
    allocate(big_up(ncol,nlev), big_dn(ncol,nlev), big_jac(ncol,nlev))
    bb_up => big_up ; bb_dn => big_dn ; bb_jac => big_jac
    bb_up = 0.0_wp ; bb_dn = 0.0_wp ; bb_jac = 0.0_wp
    write(*,'(a)') '# mode 0: CONTIGUOUS broadband targets (control)'
  end if

  write(*,'(a,i0)') '# do_rescaling = ', do_rescaling

  ! -------- the model path: do_broadband=1, do_Jacobians=1, top_at_1=1; do_rescaling per CLI --------
  call rte_lw_solver_noscat_gpu(ncol, nlay, ngpt, 1_c_int, nmus, Ds, weights, &
                                tau, lay_source, lev_source, sfc_emis, sfc_src, &
                                inc_flux, flux_up, flux_dn,                    &
                                1_c_int, bb_up, bb_dn,                         &
                                1_c_int, sfc_srcJac, bb_jac, flux_upJac,       &
                                do_rescaling, ssa, g)

  write(*,'(a)') '# ncol nlay ngpt   sum_broadband_up   sum_broadband_upJac'
  write(*,'(i6,1x,i4,1x,i4,3x,es16.8,1x,es16.8)') ncol, nlay, ngpt, sum(bb_up), sum(bb_jac)

  ! -------- VALUE scan (what memcheck and the sums cannot see) --------
  ! The in-model canary flagged NaN + |flux|>1e6 (values up to 2.1e30) on this exact call.
  ! compute-sanitizer catches only bad MEMORY access, and a sum can mask cancellation, so scan
  ! every returned array for NaN / |x|>1e6 and report the max finite magnitude. A nonzero count
  ! here reproduces the in-model device miscompute on a single GPU.
  write(*,'(a)') '# --- value scan: NaN / |x|>1e6 / max finite magnitude ---'
  call scan_values('flux_up   ', reshape(flux_up,    [size(flux_up)]))
  call scan_values('flux_dn   ', reshape(flux_dn,    [size(flux_dn)]))
  call scan_values('flux_upJac', reshape(flux_upJac, [size(flux_upJac)]))
  call scan_values('bb_up     ', reshape(bb_up,      [size(bb_up)]))
  call scan_values('bb_dn     ', reshape(bb_dn,      [size(bb_dn)]))
  call scan_values('bb_jac    ', reshape(bb_jac,     [size(bb_jac)]))

  if (mode == 1) then
    ! count guard elements OUTSIDE the intended section that were overwritten (should be ZERO)
    bad_up  = count(big_up  /= SENT) - count(bb_up  /= SENT)
    bad_dn  = count(big_dn  /= SENT) - count(bb_dn  /= SENT)
    bad_jac = count(big_jac /= SENT) - count(bb_jac /= SENT)
    write(*,'(a,i0,1x,i0,1x,i0)') '# OUT-OF-SECTION guard elements overwritten (up dn jac): ', &
                                   bad_up, bad_dn, bad_jac
    if (bad_up == 0 .and. bad_dn == 0 .and. bad_jac == 0) then
      write(*,'(a)') 'GUARD CLEAN: copyback stayed inside the non-contiguous section.'
    else
      write(*,'(a)') 'GUARD STOMPED: device->host copyback wrote OUTSIDE the section == corruption.'
    end if
  end if

contains

  ! Scan a flattened field for the same garbage the in-model canary looks for:
  ! NaN (x/=x) and |x|>1e6 (real LW fluxes are ~1e2). Report the max finite magnitude.
  subroutine scan_values(label, x)
    character(len=*), intent(in) :: label
    real(wp),         intent(in) :: x(:)
    integer  :: i, nnan, nhuge
    real(wp) :: mx, ax
    nnan = 0 ; nhuge = 0 ; mx = 0.0_wp
    do i = 1, size(x)
      if (x(i) /= x(i)) then
        nnan = nnan + 1
      else
        ax = abs(x(i))
        if (ax > 1.0e6_wp) then
          nhuge = nhuge + 1
        else if (ax > mx) then
          mx = ax
        end if
      end if
    end do
    write(*,'(a,a,a,i0,a,i0,a,es12.4)') '# scan ', label, ' : NaN=', nnan, &
          '  |x|>1e6=', nhuge, '  maxabs_finite=', mx
    if (nnan > 0 .or. nhuge > 0) &
      write(*,'(a,a,a)') 'VALUE GARBAGE in ', label, ' -- device miscompute reproduced.'
  end subroutine scan_values

end program lw_broadband_test
