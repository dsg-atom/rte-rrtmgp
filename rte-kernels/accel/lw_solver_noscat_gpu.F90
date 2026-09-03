! ------------------------------------------------------------------------------------------------
! GPU entry shim for the GEOS integration.
!
! Exports a DISTINCT C symbol `rte_lw_solver_noscat_gpu` that forwards, unchanged, to the accel
! `lw_solver_noscat` (whose own bind name is "rte_lw_solver_noscat").
!
! Why a distinct name is required, not just a direct call to rte_lw_solver_noscat:
!   The accel mo_rte_solver_kernels.F90 is compiled BOTH by ifort into the GEOS RRTMGP archive
!   AND by nvfortran into librtekernels.so, so both objects export `rte_lw_solver_noscat`. The
!   ifort object is pulled into the GEOSgcm.x link (the LW front-end uses that module for
!   lw_solver_2stream), so a front-end call to `rte_lw_solver_noscat` would bind to the ifort
!   CPU copy, not the GPU .so -- the port would run silently on the host.
!
!   This file is NOT listed in the GEOS RRTMGP CMake sources, so ifort never compiles it and
!   `rte_lw_solver_noscat_gpu` exists ONLY in the nvfortran .so. The front-end calls that name
!   and is guaranteed to reach the GPU kernel.
!
! Pure pass-through: the dummy declarations mirror the accel rte_lw_solver_noscat verbatim
! (logical(wl) flags, real(wp)==c_double arrays), so no type conversion happens here. The
! ifort caller passes the four flags as 4-byte integer(c_int) 1/0 -- the ABI proven bit-faithful
! by examples/lw-kernel-bench/lw_solver_cwrap_ifort.f90 (int caller -> logical(wl) callee).
! ------------------------------------------------------------------------------------------------
module mo_rte_lw_solver_gpu
  use mo_rte_kind,           only: wp, wl
  use mo_rte_solver_kernels, only: lw_solver_noscat
  implicit none
  private
  public :: rte_lw_solver_noscat_gpu
contains
  subroutine rte_lw_solver_noscat_gpu(ncol, nlay, ngpt, top_at_1, nmus, Ds, weights,       &
                                      tau, lay_source, lev_source, sfc_emis, sfc_src,      &
                                      inc_flux, flux_up, flux_dn,                          &
                                      do_broadband, broadband_up, broadband_dn,            &
                                      do_Jacobians, sfc_srcJac, broadband_upJac, flux_upJac, &
                                      do_rescaling, ssa, g) bind(C, name="rte_lw_solver_noscat_gpu")
    integer,                               intent(in   ) :: ncol, nlay, ngpt
    logical(wl),                           intent(in   ) :: top_at_1
    integer,                               intent(in   ) :: nmus
    real(wp), dimension(ncol,      ngpt, &
                                    nmus), intent(in   ) :: Ds
    real(wp), dimension(nmus),             intent(in   ) :: weights
    real(wp), dimension(ncol,nlay,  ngpt), intent(in   ) :: tau
    real(wp), dimension(ncol,nlay,  ngpt), intent(in   ) :: lay_source
    real(wp), dimension(ncol,nlay+1,ngpt), intent(in   ) :: lev_source
    real(wp), dimension(ncol,       ngpt), intent(in   ) :: sfc_emis
    real(wp), dimension(ncol,       ngpt), intent(in   ) :: sfc_src
    real(wp), dimension(ncol,       ngpt), intent(in   ) :: inc_flux
    real(wp), dimension(ncol,nlay+1,ngpt), target, &
                                           intent(  out) :: flux_up, flux_dn
    logical(wl),                           intent(in   ) :: do_broadband
    real(wp), dimension(ncol,nlay+1     ), target, &
                                           intent(inout) :: broadband_up, broadband_dn
    logical(wl),                           intent(in   ) :: do_Jacobians
    real(wp), dimension(ncol,       ngpt), intent(in   ) :: sfc_srcJac
    real(wp), dimension(ncol,nlay+1     ), target, &
                                           intent(  out) :: broadband_upJac
    real(wp), dimension(ncol,nlay+1,ngpt), target, &
                                           intent(  out) :: flux_upJac
    logical(wl),                           intent(in   ) :: do_rescaling
    real(wp), dimension(ncol,nlay  ,ngpt), intent(in   ) :: ssa, g

    call lw_solver_noscat(ncol, nlay, ngpt, top_at_1, nmus, Ds, weights,       &
                          tau, lay_source, lev_source, sfc_emis, sfc_src,      &
                          inc_flux, flux_up, flux_dn,                          &
                          do_broadband, broadband_up, broadband_dn,            &
                          do_Jacobians, sfc_srcJac, broadband_upJac, flux_upJac, &
                          do_rescaling, ssa, g)
  end subroutine rte_lw_solver_noscat_gpu
end module mo_rte_lw_solver_gpu
