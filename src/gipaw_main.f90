!
! Copyright (C) 2001-2009 GIPAW and Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!-----------------------------------------------------------------------
PROGRAM gipaw_main
  !-----------------------------------------------------------------------
  !
  ! ... This is the main driver of the magnetic response program. 
  ! ... It controls the initialization routines.
  ! ... Features: NMR chemical shifts
  !...            EPR g-tensor
  ! ... Ported to Espresso by:
  ! ... D. Ceresoli, A. P. Seitsonen, U. Gerstamnn and  F. Mauri
  ! ...
  ! ... References (NMR):
  ! ... F. Mauri and S. G. Louie Phys. Rev. Lett. 76, 4246 (1996)
  ! ... F. Mauri, B. G. Pfrommer, S. G. Louie, Phys. Rev. Lett. 77, 5300 (1996)
  ! ... T. Gregor, F. Mauri, and R. Car, J. Chem. Phys. 111, 1815 (1999)
  ! ... C. J. Pickard and F. Mauri, Phys. Rev. B 63, 245101 (2001)
  ! ... C. J. Pickard and F. Mauri, Phys. Rev. Lett. 91, 196401 (2003)
  ! ...
  ! ... References (g-tensor):
  ! ... C. J. Pickard and F. Mauri, Phys. Rev. Lett. 88, 086403 (2002)
  ! ...
  USE kinds,           ONLY : DP
  USE io_global,       ONLY : stdout, ionode, ionode_id, meta_ionode, meta_ionode_id
  USE io_files,        ONLY : prefix, tmp_dir, nd_nmbr
  USE klist,           ONLY : nks
  USE mp,              ONLY : mp_bcast
  USE cell_base,       ONLY : tpiba
  USE cellmd,          ONLY : cell_factor
  USE gipaw_module,    ONLY : job, q_gipaw
  USE control_flags,   ONLY : io_level, gamma_only, use_para_diag, twfcollect
  USE mp_global,       ONLY : mp_startup, my_image_id,  mpime, nproc, root
  USE check_stop,      ONLY : check_stop_init
  USE environment,     ONLY : environment_start
  USE lsda_mod,        ONLY : nspin
  USE wvfct,           ONLY : nbnd
  USE uspp,            ONLY : okvan
  USE wvfct,                ONLY : nbnd, npw 
  USE mp_image_global_module, ONLY : mp_image_startup, world_comm
  USE mp_image_global_module, ONLY : me_image, nimage, inter_image_comm, intra_image_comm
  USE mp_global,             ONLY : mp_start, mpime, nproc, root, inter_bgrp_comm, nbgrp
  USE image_io_routines, ONLY : io_image_start
  USE iotk_module  
  USE xml_io_base


  ! ... and begin with the initialization part

  !------------------------------------------------------------------------
  IMPLICIT NONE
  CHARACTER (LEN=9)   :: code = 'GIPAW'
  CHARACTER (LEN=10)  :: dirname = 'dummy'
  INTEGER             :: gipaw_comm
  !------------------------------------------------------------------------

  ! ... and begin with the initialization part
#ifdef __MPI
  CALL mp_start (nproc, mpime, gipaw_comm)
  CALL mp_image_startup(root, gipaw_comm)
  CALL engine_mp_start()
  !CALL mp_startup()
#endif

  CALL environment_start ( code )
#ifndef __BANDS
  if (nbgrp > 1) &
    call errore('gipaw_main', 'configure and recompile GIPAW with --enable-band-parallel', 1)
#endif

  CALL io_image_start()
  CALL gipaw_readin()
  CALL check_stop_init()

  io_level = 1
 
  ! read ground state wavefunctions
  cell_factor = 1.1d0
  call read_file
#ifdef __MPI
  use_para_diag = .true.
  call check_para_diag( nbnd )
#else
  use_para_diag = .FALSE.
#endif

  call gipaw_openfil
  
  if ( gamma_only ) call errore ('gipaw_main', 'Cannot run GIPAW with gamma_only == .true. ', 1)
#ifdef __BANDS
  if (nbgrp > 1 .and. (twfcollect .eqv. .false.)) &
    call errore('gipaw_main', 'Cannot use band-parallelization without wf_collect in SCF', 1)
#endif

  CALL gipaw_allocate()
  CALL gipaw_setup()
  CALL gipaw_summary()
  CALL print_clock( 'GIPAW' )
  
  ! convert q_gipaw into units of tpiba
  q_gipaw = q_gipaw / tpiba
  
 IF( nimage >= 1 ) THEN
  WRITE( dirname, FMT = '( I5.5 )' ) my_image_id
  tmp_dir = TRIM( tmp_dir ) // '/' // TRIM( dirname )
  CALL create_directory( tmp_dir )
  ENDIF 
  ! calculation
#ifdef __BANDS
  CALL init_parallel_over_band(inter_bgrp_comm, nbnd)
#endif
  select case ( trim(job) )
  case ( 'nmr' )
     call suscept_crystal   
     
  case ( 'g_tensor' )
     if (nspin /= 2) call errore('gipaw_main', 'g_tensor is only for spin-polarized', 1)
     if (okvan) call errore('gipaw_main', 'g_tensor not available with ultrasoft', 1) 
     call suscept_crystal
     
  case ( 'f-sum' )
     call suscept_crystal
     
  case ( 'efg' )
     call efg
     
  case ( 'hyperfine' )
     if (nspin /= 2) call errore('gipaw_main', 'hyperfine is only for spin-polarized', 1)
     call hyperfine
     
  case default
     call errore('gipaw_main', 'wrong or undefined job in input', 1)
  end select
  
  ! print timings and stop the code
  CALL gipaw_closefil
  CALL print_clock_gipaw()
  CALL stop_code( .TRUE. )
  
  STOP
  
END PROGRAM gipaw_main
