! ------------------------------------------------------------------------------------------------
! Cross-compiler correctness test: an IFORT-compiled caller invokes rte_lw_solver_noscat --
! the bind(C) entry of the LW no-scattering solver -- from an nvfortran-built librtekernels.so.
!
! Purpose: prove the ifort -> C-entry -> GPU .so path returns CORRECT fluxes (not just links).
! This is the real solver, not the toy scale kernel. It de-risks the GEOS integration, where the
! ifort-built radiation front-end will call this same C entry instead of the Fortran module
! routine (nvfortran .mod files are unreadable by ifort, so the C entry is the only clean door).
!
! Inputs replicate examples/lw-kernel-bench/lw_solver_bench.F90 EXACTLY, so the checksums MUST
! reproduce the recorded nvfortran reference at ncol=1024 nlay=72 ngpt=256 nmus=1:
!     sum_flux_up    = 6.80340094E+07
!     sum_flux_upJac = 1.31914742E+05
! A match proves the cross-compiler C-entry path is bit-faithful. A mismatch is the verdict on
! the logical/real ABI (retry with a different Bool representation).
!
! ABI (RTE_USE_SP and RTE_USE_CBOOL both undefined in the .so build):
!   wp = double, Float = double, Bool = int (4 byte), wl = default 4-byte logical.
!   Logical flags are passed as integer(c_int) 1/0 by reference -- the same contract RTE's own
!   C++ front-end uses for these bind(C) kernels. NOTE: rte_kernels.h is stale (its prototype
!   omits broadband_upJac); the authoritative arg list is the Fortran subroutine, matched below.
!
! Build + run: see run_cwrap_test.sbatch (ifort compile, link librtekernels.so, run on an A100).
! ------------------------------------------------------------------------------------------------
program lw_solver_cwrap_ifort
  use, intrinsic :: iso_c_binding, only: c_int, c_double
  implicit none
  integer, parameter :: wp = c_double

  interface
    subroutine rte_lw_solver_noscat(ncol, nlay, ngpt, top_at_1, nmus, Ds, weights,       &
                                    tau, lay_source, lev_source, sfc_emis, sfc_src,      &
                                    inc_flux, flux_up, flux_dn,                          &
                                    do_broadband, broadband_up, broadband_dn,            &
                                    do_Jacobians, sfc_srcJac, broadband_upJac, flux_upJac, &
                                    do_rescaling, ssa, g) bind(C, name="rte_lw_solver_noscat")
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
    end subroutine rte_lw_solver_noscat
  end interface

  integer(c_int) :: ncol, nlay, ngpt, nmus
  integer :: nargs
  character(len=32) :: arg

  real(wp), allocatable :: Ds(:,:,:), weights(:)
  real(wp), allocatable :: tau(:,:,:), lay_source(:,:,:), lev_source(:,:,:)
  real(wp), allocatable :: sfc_emis(:,:), sfc_src(:,:), inc_flux(:,:)
  real(wp), allocatable :: flux_up(:,:,:), flux_dn(:,:,:)
  real(wp), allocatable :: broadband_up(:,:), broadband_dn(:,:)
  real(wp), allocatable :: sfc_srcJac(:,:), broadband_upJac(:,:), flux_upJac(:,:,:)
  real(wp), allocatable :: ssa(:,:,:), g(:,:,:)

  ! -------- defaults / CLI (match the bench) --------
  ncol = 1024_c_int ; nlay = 72_c_int ; ngpt = 256_c_int ; nmus = 1_c_int
  nargs = command_argument_count()
  if (nargs >= 1) then ; call get_command_argument(1, arg) ; read(arg,*) ncol ; end if
  if (nargs >= 2) then ; call get_command_argument(2, arg) ; read(arg,*) nlay ; end if
  if (nargs >= 3) then ; call get_command_argument(3, arg) ; read(arg,*) ngpt ; end if
  if (nargs >= 4) then ; call get_command_argument(4, arg) ; read(arg,*) nmus ; end if

  ! -------- allocate --------
  allocate(Ds(ncol,ngpt,nmus), weights(nmus))
  allocate(tau(ncol,nlay,ngpt), lay_source(ncol,nlay,ngpt), lev_source(ncol,nlay+1,ngpt))
  allocate(sfc_emis(ncol,ngpt), sfc_src(ncol,ngpt), inc_flux(ncol,ngpt))
  allocate(flux_up(ncol,nlay+1,ngpt), flux_dn(ncol,nlay+1,ngpt))
  allocate(broadband_up(ncol,nlay+1), broadband_dn(ncol,nlay+1))
  allocate(sfc_srcJac(ncol,ngpt), broadband_upJac(ncol,nlay+1), flux_upJac(ncol,nlay+1,ngpt))
  allocate(ssa(ncol,nlay,ngpt), g(ncol,nlay,ngpt))

  ! -------- deterministic synthetic inputs (identical to lw_solver_bench.F90) --------
  Ds          = 1.66_wp
  weights     = 0.5_wp
  tau         = 0.1_wp
  lay_source  = 2.0_wp
  lev_source  = 2.0_wp
  sfc_emis    = 0.98_wp
  sfc_src     = 5.0_wp
  inc_flux    = 0.0_wp
  sfc_srcJac  = 0.05_wp
  ssa         = 0.0_wp
  g           = 0.0_wp
  flux_up = 0.0_wp ; flux_dn = 0.0_wp
  broadband_up = 0.0_wp ; broadband_dn = 0.0_wp
  broadband_upJac = 0.0_wp ; flux_upJac = 0.0_wp

  ! do_broadband=.false.(0), do_Jacobians=.true.(1), do_rescaling=.false.(0), top_at_1=.true.(1)
  call rte_lw_solver_noscat(ncol, nlay, ngpt, 1_c_int, nmus, Ds, weights,       &
                            tau, lay_source, lev_source, sfc_emis, sfc_src,     &
                            inc_flux, flux_up, flux_dn,                         &
                            0_c_int, broadband_up, broadband_dn,               &
                            1_c_int, sfc_srcJac, broadband_upJac, flux_upJac,  &
                            0_c_int, ssa, g)

  write(*,'(a)') '# ncol nlay ngpt        sum_flux_up       sum_flux_upJac'
  write(*,'(i6,1x,i4,1x,i4,3x,es16.8,1x,es16.8)') ncol, nlay, ngpt, sum(flux_up), sum(flux_upJac)
  write(*,'(a)') '# reference (nvfortran bench, 2026-09-03): 6.80340094E+07   1.31914742E+05'
end program lw_solver_cwrap_ifort
