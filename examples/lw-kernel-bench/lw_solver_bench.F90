! ------------------------------------------------------------------------------------------------
! Standalone micro-benchmark for the LW no-scattering solver kernel (lw_solver_noscat).
!
! Purpose: time / A-B the accel (GPU) vs reference (CPU) lw_solver_noscat WITHOUT any
!   netCDF, gas-optics, or frontend dependency. It links only librtekernels.a, so it builds
!   on hosts that lack an nvfortran-compatible netCDF. Inputs are synthetic (deterministic),
!   which is sufficient for timing the solver and for a bitwise/tolerance CPU-vs-GPU compare
!   of the same build inputs -- it does NOT validate physical fluxes against a reference.
!
!   It exercises do_Jacobians=.true. with do_broadband=.false., i.e. the g-point flux_upJac
!   path that GEOS uses via reduce() -- exactly the code path added in the accel patch.
!
! Usage: lw_solver_bench [ncol [nlay [ngpt [nreps [mode]]]]]
!   defaults: ncol=1024 nlay=72 ngpt=256 nreps=10   (rep 1 discarded as warm-up when nreps>1)
!   mode (accel build only): 0 = resident (default) -- inputs staged on-device once, per-rep
!         timing is compute-bound; 1 = transfer -- outer data region disabled, so each call
!         pays its own H2D/D2H round-trip via the kernel's own copyin/copyout. The 0-vs-1 gap
!         is the PCIe cost the residency design must amortize. (No effect on the CPU build.)
!
! Build twice for the A/B (see the Makefile in this directory):
!   CPU  : FC=nvfortran FCFLAGS='-O3'                    make -C ../../build librtekernels.a && make
!   accel: FC=nvfortran FCFLAGS='-O3 -acc -gpu=cc80' RTE_KERNELS=accel make -C ../../build librtekernels.a && make
! ------------------------------------------------------------------------------------------------
program lw_solver_bench
  use mo_rte_kind,           only: wp, wl
  use mo_rte_solver_kernels, only: lw_solver_noscat
  implicit none

  integer, parameter :: ik = selected_int_kind(18)

  integer :: ncol, nlay, ngpt, nmus, nreps, mode
  integer :: irep, nargs, denom
  logical(wl) :: top_at_1, do_broadband, do_Jacobians, do_rescaling
  logical :: resident
  character(len=32) :: arg
  character(len=8)  :: mode_label

  real(wp), allocatable :: Ds(:,:,:), weights(:)
  real(wp), allocatable :: tau(:,:,:), lay_source(:,:,:), lev_source(:,:,:)
  real(wp), allocatable :: sfc_emis(:,:), sfc_src(:,:), inc_flux(:,:)
  real(wp), allocatable :: flux_up(:,:,:), flux_dn(:,:,:)
  real(wp), allocatable :: broadband_up(:,:), broadband_dn(:,:)
  real(wp), allocatable :: sfc_srcJac(:,:), broadband_upJac(:,:), flux_upJac(:,:,:)
  real(wp), allocatable :: ssa(:,:,:), g(:,:,:)

  integer(ik) :: t0, t1, rate
  real(wp) :: dt, dt_min, dt_sum, mean

  ! -------- defaults / CLI --------
  ncol = 1024 ; nlay = 72 ; ngpt = 256 ; nreps = 10 ; mode = 0
  nmus = 1
  top_at_1 = .true. ; do_broadband = .false. ; do_Jacobians = .true. ; do_rescaling = .false.

  nargs = command_argument_count()
  if (nargs >= 1) then ; call get_command_argument(1, arg) ; read(arg,*) ncol  ; end if
  if (nargs >= 2) then ; call get_command_argument(2, arg) ; read(arg,*) nlay  ; end if
  if (nargs >= 3) then ; call get_command_argument(3, arg) ; read(arg,*) ngpt  ; end if
  if (nargs >= 4) then ; call get_command_argument(4, arg) ; read(arg,*) nreps ; end if
  if (nargs >= 5) then ; call get_command_argument(5, arg) ; read(arg,*) mode  ; end if

  resident   = (mode == 0)
  mode_label = merge('resident', 'transfer', resident)

  ! -------- allocate --------
  allocate(Ds(ncol,ngpt,nmus), weights(nmus))
  allocate(tau(ncol,nlay,ngpt), lay_source(ncol,nlay,ngpt), lev_source(ncol,nlay+1,ngpt))
  allocate(sfc_emis(ncol,ngpt), sfc_src(ncol,ngpt), inc_flux(ncol,ngpt))
  allocate(flux_up(ncol,nlay+1,ngpt), flux_dn(ncol,nlay+1,ngpt))
  allocate(broadband_up(ncol,nlay+1), broadband_dn(ncol,nlay+1))
  allocate(sfc_srcJac(ncol,ngpt), broadband_upJac(ncol,nlay+1), flux_upJac(ncol,nlay+1,ngpt))
  allocate(ssa(ncol,nlay,ngpt), g(ncol,nlay,ngpt))

  ! -------- deterministic synthetic inputs (physically plausible, not a reference profile) --------
  Ds          = 1.66_wp     ! diffusivity secant
  weights     = 0.5_wp
  tau         = 0.1_wp
  lay_source  = 2.0_wp
  lev_source  = 2.0_wp
  sfc_emis    = 0.98_wp
  sfc_src     = 5.0_wp
  inc_flux    = 0.0_wp
  sfc_srcJac  = 0.05_wp
  ssa         = 0.0_wp      ! unused (do_rescaling=.false.) but must be allocated
  g           = 0.0_wp
  flux_up = 0.0_wp ; flux_dn = 0.0_wp
  broadband_up = 0.0_wp ; broadband_dn = 0.0_wp
  broadband_upJac = 0.0_wp ; flux_upJac = 0.0_wp

  call system_clock(count_rate=rate)
  dt_min = huge(1.0_wp) ; dt_sum = 0.0_wp

  ! Outer device-data region (active only in the accel build; plain comments for CPU).
  ! When resident (mode 0) it stages inputs once so the kernel's own copyin/out find data
  ! present -> per-rep timing is compute-bound (transfers amortized outside the loop).
  ! When mode 1, if(resident)=.false. makes this construct a no-op, so each kernel call does
  ! its own H2D/D2H -> per-rep timing includes the full PCIe round-trip.
  !$acc data copyin(Ds,weights,tau,lay_source,lev_source,sfc_emis,sfc_src,inc_flux,sfc_srcJac,ssa,g) &
  !$acc      copyout(flux_up,flux_dn,broadband_upJac,flux_upJac) &
  !$acc      create(broadband_up,broadband_dn) if(resident)
  do irep = 1, nreps
    call system_clock(t0)
    call lw_solver_noscat(ncol, nlay, ngpt, top_at_1,           &
                          nmus, Ds, weights,                    &
                          tau, lay_source, lev_source,          &
                          sfc_emis, sfc_src, inc_flux,          &
                          flux_up, flux_dn,                     &
                          do_broadband, broadband_up, broadband_dn, &
                          do_Jacobians, sfc_srcJac, broadband_upJac, flux_upJac, &
                          do_rescaling, ssa, g)
    call system_clock(t1)
    dt = real(t1 - t0, wp) / real(rate, wp)
    if (irep > 1 .or. nreps == 1) then
      dt_min = min(dt_min, dt)
      dt_sum = dt_sum + dt
    end if
  end do
  !$acc end data

  denom = merge(nreps - 1, 1, nreps > 1)
  mean  = dt_sum / real(denom, wp)

  write(*,'(a)') '# ncol   nlay ngpt nreps  mode      call_ms_min  call_ms_mean   per_col_us      sum_flux_up       sum_flux_upJac'
  write(*,'(i8,1x,i4,1x,i4,1x,i5,2x,a8,2x,f12.5,1x,f12.5,1x,f12.5,3x,es16.8,1x,es16.8)') &
       ncol, nlay, ngpt, nreps, mode_label, &
       dt_min*1.0e3_wp, mean*1.0e3_wp, dt_min*1.0e6_wp/real(ncol,wp), &
       sum(flux_up), sum(flux_upJac)

end program lw_solver_bench
