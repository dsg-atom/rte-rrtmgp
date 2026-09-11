! ------------------------------------------------------------------------------------------------
! Reproducer for the in-model GPU crash: the BLOCKED call pattern the model actually uses.
!
! Reading GEOS_IrradGridComp.F90 settled the width question for free. PROCESS_RRTMGP_LW_BLOCK
! computes, per block b (lines 3922-3924):
!     ncols_block = min(rrtmgp_blockSize, ncol - (b-1)*rrtmgp_blockSize)
!     colS = (b-1)*rrtmgp_blockSize + 1
!     colE = colS + ncols_block - 1
! and allocates the optical props with alloc_2str(ncols_block, ...) and points the flux at
! flux_up_clrnoa(colS:colE,:). So the ncol the solver sees == colE-colS+1 == ncols_block for
! EVERY block. There is no width mismatch. That hypothesis is dead.
!
! But those same three lines expose two things nothing has tested:
!   (1) The FINAL block is PARTIAL whenever a rank's column count is not a multiple of 4. That
!       block calls the solver with ncols_block = 1, 2, or 3. Roughly three ranks in four hit
!       this every longwave step. Every prior test used width 4 or 2048 -- never 1/2/3.
!   (2) A rank makes ~ceil(ncol/4) blocks * 4 flavors ~= thousands of solver calls per LW step.
!       Device allocate/free churn across thousands of back-to-back calls is untested.
!
! The in-model failure is a HOST memory stomp (land-tile areas "do not add to 1"), the FIRST
! symptom, long before any NaN. This program mimics the model pattern: one big host flux array of
! NCOL+GUARD columns, sentinel-filled; loop b=1..ceil(NCOL/BLK), each block a NON-CONTIGUOUS
! (colS:colE,:) slice of that array (exactly what GEOS passes); the final block is partial when
! NCOL is not a multiple of BLK. Inputs are passed as (1:ncols_block) sections so the solver's
! ncol argument shrinks on the partial block, just as in the model. After all blocks it checks:
!   - trailing GUARD columns still all equal the sentinel (any change == a copyback overflow),
!   - processed columns all finite and no longer sentinel (all written, no NaN/Inf).
! Run under compute-sanitizer memcheck (see run_blocked_test.sbatch).
!
! Build: same as the other bench tests (ifort caller, link librtekernels.so).
! Usage: ./lw_blocked  ncol nlay ngpt blk        (default ncol=4093 -> last block is 1 column)
! ------------------------------------------------------------------------------------------------
program lw_blocked_test
  use, intrinsic :: iso_c_binding, only: c_int, c_double
  implicit none
  integer, parameter :: wp = c_double
  real(wp), parameter :: SENT = -987654.0_wp   ! sentinel in never-written guard columns
  integer, parameter :: GUARD = 64             ! trailing guard columns no block ever touches

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

  integer(c_int) :: nlay, ngpt, nmus
  integer :: blk, ncol, nlev, nblocks, b, cs, ce, nb
  integer :: bad_guard_up, bad_guard_dn, bad_guard_jac, nan_up, unwritten_up
  integer :: min_block, max_block
  character(len=32) :: arg

  ! per-block inputs allocated at MAX width (blk); the partial block passes only its first nb cols
  real(wp), allocatable :: Ds(:,:,:), weights(:)
  real(wp), allocatable :: tau(:,:,:), lay_source(:,:,:), lev_source(:,:,:)
  real(wp), allocatable :: sfc_emis(:,:), sfc_src(:,:), inc_flux(:,:)
  real(wp), allocatable :: flux_up(:,:,:), flux_dn(:,:,:), flux_upJac(:,:,:)
  real(wp), allocatable :: sfc_srcJac(:,:), ssa(:,:,:), g(:,:,:)
  ! big shared output arrays (NCOL + GUARD columns), written a slice at a time
  real(wp), allocatable, target :: big_up(:,:), big_dn(:,:), big_jac(:,:)

  ! -------- CLI (default ncol=4093 = 1024 blocks of 4 with a final PARTIAL block of 1) --------
  ncol = 4093 ; nlay = 91_c_int ; ngpt = 128_c_int ; blk = 4 ; nmus = 1_c_int
  if (command_argument_count() >= 1) then ; call get_command_argument(1, arg) ; read(arg,*) ncol ; end if
  if (command_argument_count() >= 2) then ; call get_command_argument(2, arg) ; read(arg,*) nlay ; end if
  if (command_argument_count() >= 3) then ; call get_command_argument(3, arg) ; read(arg,*) ngpt ; end if
  if (command_argument_count() >= 4) then ; call get_command_argument(4, arg) ; read(arg,*) blk  ; end if
  nlev = nlay + 1
  nblocks = (ncol + blk - 1) / blk          ! ceil -- exactly the model's nBlocks
  write(*,'(a,i0,a,i0,a,i0,a,i0,a,i0)') '# ncol=', ncol, ' blk=', blk, ' nblocks=', nblocks, &
        ' final_block_width=', ncol-(nblocks-1)*blk, ' levels=', nlev

  ! -------- per-block inputs at max width; rescaling ssa/g like the model path --------
  allocate(Ds(blk,ngpt,nmus), weights(nmus))
  allocate(tau(blk,nlay,ngpt), lay_source(blk,nlay,ngpt), lev_source(blk,nlev,ngpt))
  allocate(sfc_emis(blk,ngpt), sfc_src(blk,ngpt), inc_flux(blk,ngpt))
  allocate(flux_up(blk,nlev,ngpt), flux_dn(blk,nlev,ngpt), flux_upJac(blk,nlev,ngpt))
  allocate(sfc_srcJac(blk,ngpt), ssa(blk,nlay,ngpt), g(blk,nlay,ngpt))
  Ds = 1.66_wp ; weights = 0.5_wp ; tau = 0.1_wp
  lay_source = 2.0_wp ; lev_source = 2.0_wp ; sfc_emis = 0.98_wp ; sfc_src = 5.0_wp
  inc_flux = 0.0_wp ; sfc_srcJac = 0.05_wp ; ssa = 0.5_wp ; g = 0.6_wp
  flux_up = 0.0_wp ; flux_dn = 0.0_wp ; flux_upJac = 0.0_wp

  ! -------- one big shared output array per field, sentinel-filled --------
  allocate(big_up (ncol+GUARD, nlev), big_dn (ncol+GUARD, nlev), big_jac(ncol+GUARD, nlev))
  big_up = SENT ; big_dn = SENT ; big_jac = SENT

  ! -------- the model pattern: loop blocks, each a non-contiguous slice; last block partial --------
  min_block = blk ; max_block = 0
  do b = 1, nblocks
    cs = (b-1)*blk + 1
    nb = min(blk, ncol - (b-1)*blk)     ! ncols_block: shrinks on the final partial block
    ce = cs + nb - 1
    min_block = min(min_block, nb) ; max_block = max(max_block, nb)
    ! pass (1:nb) input sections so the solver's ncol argument is nb (== the model's ncols_block)
    call rte_lw_solver_noscat_gpu(nb, nlay, ngpt, 1_c_int, nmus, Ds(1:nb,:,:), weights, &
                                  tau(1:nb,:,:), lay_source(1:nb,:,:), lev_source(1:nb,:,:), &
                                  sfc_emis(1:nb,:), sfc_src(1:nb,:), inc_flux(1:nb,:),      &
                                  flux_up(1:nb,:,:), flux_dn(1:nb,:,:),                     &
                                  1_c_int, big_up(cs:ce,:), big_dn(cs:ce,:),                &
                                  1_c_int, sfc_srcJac(1:nb,:), big_jac(cs:ce,:), flux_upJac(1:nb,:,:), &
                                  1_c_int, ssa(1:nb,:,:), g(1:nb,:,:))
  end do
  write(*,'(a,i0,a,i0)') '# block widths seen: min=', min_block, ' max=', max_block

  ! -------- checks --------
  ! (1) trailing GUARD columns must be untouched (any change == a copyback overflowed its block)
  bad_guard_up  = count(big_up (ncol+1:ncol+GUARD,:) /= SENT)
  bad_guard_dn  = count(big_dn (ncol+1:ncol+GUARD,:) /= SENT)
  bad_guard_jac = count(big_jac(ncol+1:ncol+GUARD,:) /= SENT)
  ! (2) processed columns must be fully written (no leftover sentinel) and finite (no NaN/Inf)
  unwritten_up = count(big_up(1:ncol,:) == SENT)
  nan_up       = count(.not. (big_up(1:ncol,:) == big_up(1:ncol,:)))   ! NaN != itself

  write(*,'(a,i0,1x,i0,1x,i0)') '# GUARD columns overwritten (up dn jac): ', &
        bad_guard_up, bad_guard_dn, bad_guard_jac
  write(*,'(a,i0)')             '# processed up-columns left unwritten:   ', unwritten_up
  write(*,'(a,i0)')             '# processed up-columns that are NaN:      ', nan_up
  write(*,'(a,es16.8)')         '# sum of processed broadband_up:          ', sum(big_up(1:ncol,:))

  if (bad_guard_up==0 .and. bad_guard_dn==0 .and. bad_guard_jac==0 .and. &
      unwritten_up==0 .and. nan_up==0) then
    write(*,'(a)') 'BLOCKED CLEAN: every slice (incl. the partial final block) stayed in bounds; guards intact; no NaN.'
  else
    write(*,'(a)') 'BLOCKED STOMP: a copyback wrote outside its slice (or left gaps/NaN) == the in-model corruption.'
  end if
end program lw_blocked_test
