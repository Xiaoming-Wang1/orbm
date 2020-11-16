!
! Copyright (C) 2001-2013 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!-----------------------------------------------------------------------
SUBROUTINE calc_elec_dipole
  !-----------------------------------------------------------------------
  !
  ! This routine calculates the electric transition dipole matrix
  !                         - <n|r|m>
  !
  USE kinds,                  ONLY : dp
  USE io_global,              ONLY : stdout, ionode, ionode_id
  USE io_files,               ONLY : nwordwfc, iunwfc
  USE cell_base,              ONLY : tpiba2
  USE wavefunctions,          ONLY : evc
  USE noncollin_module,       ONLY : npol
  USE klist,                  ONLY : nks, wk, xk, igk_k, ngk, nkstot
  USE wvfct,                  ONLY : nbnd, npwx, wg, g2kin, current_k,et
  USE ener,                   ONLY : ef
  USE uspp,                   ONLY : nkb, vkb
  USE gvect,                  ONLY : ngm, g
  USE gvecw,                  ONLY : gcutw
  USE lsda_mod,               ONLY : lsda, current_spin, isk, nspin
  USE becmod,                 ONLY : becp, calbec, allocate_bec_type, deallocate_bec_type
  USE orbm_module,            ONLY : q_orbm, iverbosity, alpha, &
                                     nbnd_occ, conv_threshold, restart_mode, ry2ha
  USE buffers,                ONLY : get_buffer
  USE mp_pools,               ONLY : my_pool_id, me_pool, root_pool,  &
                                     inter_pool_comm, intra_pool_comm, npool
  USE mp,                     ONLY : mp_sum

  !-- local variables ----------------------------------------------------
  IMPLICIT NONE

  ! the following three quantities are for norm-conserving PPs
  complex(dp), allocatable, dimension(:,:,:) :: vel_evc       ! v_{k,k}|evc>
  complex(dp), allocatable, dimension(:,:,:) :: evc1          ! du/dk
  complex(dp), allocatable, dimension(:,:,:,:) :: rmat_          ! 
  complex(dp), allocatable, dimension(:,:,:,:) :: rmat          !
  complex(dp), allocatable, dimension(:,:,:) :: ps            ! <n|v|m> 
  ! temporary working array, same size as evc/evq
  complex(dp), allocatable :: aux(:,:)
  complex(dp), allocatable :: hpsi(:)
  real(dp) :: de_thr = 1.0d-7

  integer :: ik, ios, iunout
  integer :: i, ibnd, jbnd, ii, jj
  real(dp) :: q(3)
  complex(dp) :: braket
  complex(dp), external :: zdotc
  real(dp), external :: get_clock
  integer, external :: find_free_unit
  integer :: npw

 
  call start_clock('calc_elec_dipole')
  !-----------------------------------------------------------------------
  ! allocate memory
  !-----------------------------------------------------------------------
  allocate ( vel_evc(npwx*npol,nbnd,3), evc1(npwx*npol,nbnd,3),ps(nbnd, nbnd, 3))
  allocate ( rmat(nbnd,nbnd,nkstot,3),  rmat_(nbnd,nbnd, nks, 3) )
  allocate ( aux(npwx*npol,nbnd),  hpsi(npwx*npol) )

  ! print memory estimate
  call orbm_memory_report

  write(stdout, '(5X,''Computing the electric dipole matrix (e bohr):'',$)')


  !====================================================================
  ! loop over k-points on the pool
  !====================================================================
  do ik = 1, nks

#ifdef __MPI
    if (me_pool == root_pool) &
    write(*, '(5X,''k-point #'',I5,'' of '',I5,6X,''pool #'',I3,4X,''cpu time:'',F10.1)') &
      ik, nks, my_pool_id+1, get_clock('orbm')
#else
    write(stdout, '(5X,''k-point #'',I5,'' of '',I5,4X,''cpu time:'',F10.1)') &
      ik, nks, get_clock('orbm')
#endif

    ! initialize k, spin, g2kin used in h_psi    
    current_k = ik
    if (lsda) current_spin = isk(ik)
    npw = ngk(ik)
    call gk_sort(xk(1,ik), ngm, g, gcutw, npw, igk_k(1,ik), g2kin)
    g2kin(:) = g2kin(:) * tpiba2
    call init_us_2(npw, igk_k(1,ik), xk(1,ik), vkb)


    ! read wfcs from file and compute becp
    call get_buffer (evc, nwordwfc, iunwfc, ik)
    
    
    ! calculate du/dk    
    vel_evc(:,:,:) = (0.d0,0.d0)
    ps(:,:,:)= (0.d0,0.d0)
    do i = 1,3
       call apply_vel(evc, vel_evc(1,1,i), ik, i)
       !aux(:,:) = vel_evc(:,:,i)
       !call greenfunction(ik, aux, evc1(1,1,i))
       
       ! calculate the velocity matrix ps(nbnd,nbnd)
       if (noncolin) then
     
          CALL zgemm('C', 'N', nbnd, nbnd, npwx*npol, (1.d0,0.d0), evc(1,1), &
                    npwx*npol, vel_evc(1,1,i), npwx*npol, (0.d0,0.d0), ps(1,1,i), nbnd)
       else
       
          CALL zgemm('C', 'N', nbnd, nbnd, npw, (1.d0,0.d0), evc(1,1), &
                    npwx, vel_evc(1,1,i), npwx, (0.d0,0.d0), ps(1,1,i), nbnd)
       endif
       
    enddo
    
#ifdef __MPI
    call mp_sum(ps, intra_pool_comm)
#endif 
    
    ! electric dipole matrix 
    ! <n|r|m> = i\hbar <n|v|m> / (e_m - e_n)
    
    do ibnd = 1, nbnd
       do jbnd = 1, nbnd
          if ( abs(et(ibnd,ik)-et(jbnd,ik)) < de_thr )  then
             rmat_(jbnd, ibnd, ik, :) = (0.d0,0.d0)
          else
             rmat_(jbnd, ibnd, ik, :) = ps(jbnd, ibnd, :)*(0.0_dp, 1.0_dp)/ & 
                                (et(ibnd,ik) - et(jbnd,ik))/ry2ha
          endif
       enddo
    enddo
  enddo ! ik
  
  rmat_ = rmat_*(-1.0_DP)

  if ( npool == 1 ) then
     rmat = rmat_
  else
     call poolcollect_z( nbnd, nks, rmat_, nkstot, rmat)
  endif
  
  ios = 0
  if ( ionode ) then
     iunout = find_free_unit
     open (unit = iunout, file = 'edipole', status = 'unknown', form = &
          'unformatted', iostat = ios)
     rewind (iunout)
  endif

  call mp_bcast (ios, ionode_id, world_comm)
  if ( ios/=0 ) call errore ('calc_elec_dipole', 'Opening file edipole', abs (ios) )

  if (ionode) then
     write(iunout) nbnd, nkstot, nspin
     write(iunout) rmat
     close(iunout)
  endif
  
  !====================================================================
  ! print out results
  !====================================================================
  write(stdout,*)
  write(stdout,'(5X,''End of electric dipole calculation'')')
  write(stdout,*)
  write(stdout,'(5X,A) 'Matrix elements dumped in edipole'
  write(stdout,*)

  ! free memory as soon as possible
  deallocate( vel_evc, aux, evc1, hpsi, ps, rmat, rmat_ )

  
  !call restart_cleanup ( )
  call stop_clock('calc_elec_dipole')

END SUBROUTINE calc_elec_dipole
