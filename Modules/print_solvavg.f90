!
! Copyright (C) 2016 National Institute of Advanced Industrial Science and Technology (AIST)
! [ This code is written by Satomichi Nishihara. ]
!
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!---------------------------------------------------------------------------
SUBROUTINE print_solvavg(rismt, ext, ierr)
  !---------------------------------------------------------------------------
  !
  ! ... print 3D-RISM's or Laue-RISM's correlations as planar average.
  !
  USE err_rism,  ONLY : IERR_RISM_NULL, IERR_RISM_INCORRECT_DATA_TYPE
  USE io_files,  ONLY : tmp_dir, prefix
  USE io_global, ONLY : ionode
  USE kinds,     ONLY : DP
  USE mp,        ONLY : mp_rank, mp_sum, mp_max
  USE rism,      ONLY : rism_type, ITYPE_3DRISM, ITYPE_LAUERISM
  USE solvavg,   ONLY : solvavg_init, solvavg_clear, solvavg_print
  !
  IMPLICIT NONE
  !
  TYPE(rism_type),  INTENT(IN)  :: rismt
  CHARACTER(LEN=*), INTENT(IN)  :: ext
  INTEGER,          INTENT(OUT) :: ierr
  !
  INTEGER            :: io_group_id
  INTEGER            :: my_group_id
  INTEGER            :: ista
  CHARACTER(LEN=256) :: filave
  !
  ! ... check data type
  IF (rismt%itype /= ITYPE_3DRISM .AND. rismt%itype /= ITYPE_LAUERISM) THEN
    ierr = IERR_RISM_INCORRECT_DATA_TYPE
    RETURN
  END IF
  !
  ! ... get process info.
  my_group_id = mp_rank(rismt%mp_site%inter_sitg_comm)
  !
  ! ... find the index of the group which includes ionode
  io_group_id = 0
  IF (ionode) THEN
    io_group_id = my_group_id
  END IF
  CALL mp_sum(io_group_id, rismt%mp_site%intra_sitg_comm)
  CALL mp_sum(io_group_id, rismt%mp_site%inter_sitg_comm)
  !
  ! ... init solvavg
  IF (my_group_id == io_group_id) THEN
    IF (rismt%itype == ITYPE_3DRISM) THEN
      CALL solvavg_init(rismt%cfft%dfftt, rismt%mp_site%intra_sitg_comm, .FALSE.)
    ELSE !IF (rismt%itype == ITYPE_LAUERISM) THEN
      CALL solvavg_init(rismt%lfft, rismt%mp_site%intra_sitg_comm, .FALSE.)
    END IF
  END IF
  !
  ! ... put data to solvavg
  IF (rismt%itype == ITYPE_3DRISM) THEN
    CALL print_solvavg_3drism(rismt, io_group_id, my_group_id)
  ELSE !IF (rismt%itype == ITYPE_LAUERISM) THEN
    CALL print_solvavg_lauerism(rismt, io_group_id, my_group_id)
  END IF
  !
  ! ... print solvavg
  IF (my_group_id == io_group_id) THEN
    filave = TRIM(tmp_dir) // TRIM(prefix) // '.' // TRIM(ext)
    CALL solvavg_print(filave, &
    & 'solvent densities and electrostatic potentials which act on electron', ista)
    ista = ABS(ista)
  ELSE
    ista = 0
  END IF
  !
  CALL mp_max(ista, rismt%mp_site%inter_sitg_comm)
  !
  IF (ista /= 0) THEN
    CALL errore('print_solvavg', 'cannot write file' // TRIM(filave), ista)
  END IF
  !
  ! ... finalize solvavg
  IF (my_group_id == io_group_id) THEN
    CALL solvavg_clear()
  END IF
  !
  ! ... normally done
  ierr = IERR_RISM_NULL
  !
END SUBROUTINE print_solvavg
!
!---------------------------------------------------------------------------
SUBROUTINE print_solvavg_3drism(rismt, io_group_id, my_group_id)
  !---------------------------------------------------------------------------
  !
  USE constants,      ONLY : RYTOEV, K_BOLTZMANN_RY, BOHR_RADIUS_ANGS
  USE control_flags,  ONLY : gamma_only
  USE fft_interfaces, ONLY : invfft
  USE io_global,      ONLY : ionode
  USE kinds,          ONLY : DP
  USE mp,             ONLY : mp_sum, mp_get, mp_barrier
  USE rism,           ONLY : rism_type
  USE solvavg,        ONLY : solvavg_size, solvavg_put, solvavg_add
  USE solvmol,        ONLY : solVs, get_nuniq_in_solVs, &
                           & iuniq_to_isite, iuniq_to_nsite, isite_to_isolV, isite_to_iatom
  !
  IMPLICIT NONE
  !
  TYPE(rism_type), INTENT(IN) :: rismt
  INTEGER,         INTENT(IN) :: io_group_id
  INTEGER,         INTENT(IN) :: my_group_id
  !
  REAL(DP) :: beta
  !
  INTEGER, PARAMETER :: LEN_SATOM = 6
  !
  ! ... beta = 1 / (kB * T)
  beta = 1.0_DP / K_BOLTZMANN_RY / rismt%temp
  !
  ! ... put data
  CALL put_solvent()
  CALL put_solute()
  CALL put_vtotal()
  CALL put_solvent_g()
  CALL put_solvent_h()
  CALL put_solvent_c()
  CALL put_solvent_u()
  CALL put_solvent_t()
  !
CONTAINS
  !
  SUBROUTINE put_vtotal()
    IMPLICIT NONE
    !
    INTEGER                  :: ig
    INTEGER                  :: ir
    REAL(DP),    ALLOCATABLE :: vpot(:)
    COMPLEX(DP), ALLOCATABLE :: auxs(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    IF (rismt%ng < 1 .OR. rismt%ng < rismt%cfft%ngmt) THEN
      RETURN
    END IF
    !
    IF (my_group_id == io_group_id) THEN
      !
      ! ... allocate memory
      ALLOCATE(vpot(rismt%nr))
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        ALLOCATE(auxs(rismt%cfft%dfftt%nnr))
      END IF
      !
      ! ... Vsolute
      vpot = -rismt%vsr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_total (eV)', .FALSE., vpot)
      !
      vpot = -rismt%vlr * RYTOEV  ! acting on electron
      CALL solvavg_add(solvavg_size(),     .FALSE., vpot)
      !
      ! ... Vsolv
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        auxs = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      DO ig = 1, rismt%cfft%ngmt
        auxs(rismt%cfft%nlt(ig)) = rismt%vpot(ig)
      END DO
      IF (gamma_only) THEN
        DO ig = rismt%cfft%gstart_t, rismt%cfft%ngmt
          auxs(rismt%cfft%nltm(ig)) = CONJG(auxs(rismt%cfft%nlt(ig)))
        END DO
      END IF
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL invfft('Custom', auxs, rismt%cfft%dfftt)
      END IF
      !
      vpot = 0.0_DP
      DO ir = 1, rismt%cfft%dfftt%nnr
        vpot(ir) = -DBLE(auxs(ir)) * RYTOEV  ! acting on electron
      END DO
      !
      CALL solvavg_add(solvavg_size(),     .FALSE., vpot)
      !
      ! ... deallocate memory
      DEALLOCATE(vpot)
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        DEALLOCATE(auxs)
      END IF
      !
    END IF
    !
  END SUBROUTINE put_vtotal
  !
  SUBROUTINE put_solute()
    IMPLICIT NONE
    !
    REAL(DP), ALLOCATABLE :: vpot(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    IF (my_group_id == io_group_id) THEN
      !
      ALLOCATE(vpot(rismt%nr))
#if defined (__DEBUG_RISM)
      !
      ! ... Vshort
      vpot = -rismt%vsr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_short (eV)' , .FALSE., vpot)
      !
      ! ... Vlong
      vpot = -rismt%vlr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_long (eV)'  , .FALSE., vpot)
#endif
      !
      ! ... Vsolute
      vpot = -rismt%vsr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_solute (eV)', .FALSE., vpot)
      !
      vpot = -rismt%vlr * RYTOEV  ! acting on electron
      CALL solvavg_add(solvavg_size(),       .FALSE., vpot)
      !
      DEALLOCATE(vpot)
      !
    END IF
    !
  END SUBROUTINE put_solute
  !
  SUBROUTINE put_solvent()
    IMPLICIT NONE
    !
    INTEGER                  :: ig
    INTEGER                  :: ir
    REAL(DP),    ALLOCATABLE :: rhor(:)
    REAL(DP),    ALLOCATABLE :: vpor(:)
    COMPLEX(DP), ALLOCATABLE :: auxs(:)
    !
    IF (rismt%ng < 1 .OR. rismt%ng < rismt%cfft%ngmt) THEN
      RETURN
    END IF
    !
    IF (my_group_id == io_group_id) THEN
      !
      ! ... allocate memory
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        ALLOCATE(rhor(rismt%cfft%dfftt%nnr))
        ALLOCATE(vpor(rismt%cfft%dfftt%nnr))
        ALLOCATE(auxs(rismt%cfft%dfftt%nnr))
      END IF
      !
      ! ... Rho
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        auxs = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      DO ig = 1, rismt%cfft%ngmt
        auxs(rismt%cfft%nlt(ig)) = rismt%rhog(ig)
      END DO
      IF (gamma_only) THEN
        DO ig = rismt%cfft%gstart_t, rismt%cfft%ngmt
          auxs(rismt%cfft%nltm(ig)) = CONJG(auxs(rismt%cfft%nlt(ig)))
        END DO
      END IF
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL invfft('Custom', auxs, rismt%cfft%dfftt)
      END IF
      !
      DO ir = 1, rismt%cfft%dfftt%nnr
        rhor(ir) = DBLE(auxs(ir)) / BOHR_RADIUS_ANGS
      END DO
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL solvavg_put('Tot chg (e/A)', .TRUE., rhor)
      END IF
      !
      ! ... Vsolv
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        auxs = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      DO ig = 1, rismt%cfft%ngmt
        auxs(rismt%cfft%nlt(ig)) = rismt%vpot(ig)
      END DO
      IF (gamma_only) THEN
        DO ig = rismt%cfft%gstart_t, rismt%cfft%ngmt
          auxs(rismt%cfft%nltm(ig)) = CONJG(auxs(rismt%cfft%nlt(ig)))
        END DO
      END IF
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL invfft('Custom', auxs, rismt%cfft%dfftt)
      END IF
      !
      DO ir = 1, rismt%cfft%dfftt%nnr
        vpor(ir) = -DBLE(auxs(ir)) * RYTOEV  ! acting on electron
      END DO
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL solvavg_put('Avg v_solvent (eV)', .FALSE., vpor)
      END IF
      !
      ! ... deallocate memory
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        DEALLOCATE(rhor)
        DEALLOCATE(vpor)
        DEALLOCATE(auxs)
      END IF
      !
    END IF
    !
  END SUBROUTINE put_solvent
  !
  SUBROUTINE put_solvent_g()
    IMPLICIT NONE
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: nv
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP)                 :: rhov
    REAL(DP), ALLOCATABLE    :: rhor(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(rhor(rismt%nr))
    !
    ! ... Guv
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      nv    = iuniq_to_nsite(iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      rhov  = solVs(isolV)%density
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhor = rismt%gr(:, iq - rismt%mp_site%isite_start + 1) * (DBLE(nv) * rhov / BOHR_RADIUS_ANGS)
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Tot rho_'// TRIM(satom) //' (1/A)', .TRUE., rhor)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(rhor)
    !
  END SUBROUTINE put_solvent_g
  !
  SUBROUTINE put_solvent_h()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP), ALLOCATABLE    :: rhor(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(rhor(rismt%nr))
    !
    ! ... Huv
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhor = rismt%hr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg h_'// TRIM(satom), .FALSE., rhor)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(rhor)
    !
#endif
  END SUBROUTINE put_solvent_h
  !
  SUBROUTINE put_solvent_c()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP), ALLOCATABLE    :: rhor(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(rhor(rismt%nr))
    !
    ! ... Csuv
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhor = rismt%csr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg cs_'// TRIM(satom), .FALSE., rhor)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Cuv
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhor = rismt%csr(:, iq - rismt%mp_site%isite_start + 1) &
    & - beta * rismt%ulr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg c_'// TRIM(satom), .FALSE., rhor)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(rhor)
    !
#endif
  END SUBROUTINE put_solvent_c
  !
  SUBROUTINE put_solvent_u()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP), ALLOCATABLE    :: vpot(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(vpot(rismt%nr))
    !
    ! ... Ulj
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = beta * rismt%uljr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg uLJ_'// TRIM(satom) // ' (kT)', .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! .. Usuv
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = beta * rismt%usr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg us_'// TRIM(satom) // ' (kT)', .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Uluv
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = beta * rismt%ulr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg ul_'// TRIM(satom) // ' (kT)', .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Uuv
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = beta * (rismt%usr(:, iq - rismt%mp_site%isite_start + 1) &
                   & + rismt%ulr(:, iq - rismt%mp_site%isite_start + 1))
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg u_'// TRIM(satom) // ' (kT)', .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(vpot)
    !
#endif
  END SUBROUTINE put_solvent_u
  !
  SUBROUTINE put_solvent_t()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP), ALLOCATABLE    :: vpot(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(vpot(rismt%nr))
    !
    ! ... -beta * Uuv + Huv - Cuv, R-space
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = -beta * rismt%usr(:, iq - rismt%mp_site%isite_start + 1) &
                   & + rismt%hr (:, iq - rismt%mp_site%isite_start + 1) &
                   & - rismt%csr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg t_'// TRIM(satom), .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(vpot)
    !
#endif
  END SUBROUTINE put_solvent_t
  !
END SUBROUTINE print_solvavg_3drism
!
!---------------------------------------------------------------------------
SUBROUTINE print_solvavg_lauerism(rismt, io_group_id, my_group_id)
  !---------------------------------------------------------------------------
  !
  USE constants,      ONLY : RYTOEV, K_BOLTZMANN_RY, BOHR_RADIUS_ANGS
  USE control_flags,  ONLY : gamma_only
  USE fft_interfaces, ONLY : invfft
  USE kinds,          ONLY : DP
  USE lauefft,        ONLY : fw_lauefft_2xy
  USE mp,             ONLY : mp_sum, mp_get, mp_barrier
  USE rism,           ONLY : rism_type
  USE rism1d_facade,  ONLY : rism1t
  USE solvavg,        ONLY : solvavg_size, solvavg_put, solvavg_add
  USE solvmol,        ONLY : solVs, get_nuniq_in_solVs, &
                           & iuniq_to_isite, iuniq_to_nsite, isite_to_isolV, isite_to_iatom
  !
  IMPLICIT NONE
  !
  TYPE(rism_type), INTENT(IN) :: rismt
  INTEGER,         INTENT(IN) :: io_group_id
  INTEGER,         INTENT(IN) :: my_group_id
  !
  REAL(DP) :: beta
  !
  INTEGER, PARAMETER :: LEN_SATOM = 6
  !
  ! ... beta = 1 / (kB * T)
  beta = 1.0_DP / K_BOLTZMANN_RY / rismt%temp
  !
  ! ... put data
  CALL put_solvent()
  CALL put_solvent_pbc()
  CALL put_solute()
  CALL put_vtotal()
  CALL put_solvent_g()
  CALL put_solvent_h()
  CALL put_solvent_c()
  CALL put_solvent_u()
  CALL put_solvent_t()
  !
CONTAINS
  !
  SUBROUTINE put_vtotal()
    IMPLICIT NONE
    !
    REAL(DP),    ALLOCATABLE :: vpot(:)
    COMPLEX(DP), ALLOCATABLE :: vpol(:)
    !
    IF (rismt%nr < 1 .OR. (rismt%nrzl * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF (my_group_id == io_group_id) THEN
      !
      ALLOCATE(vpot(rismt%nr))
      ALLOCATE(vpol(rismt%ngxy * rismt%nrzl))
      !
      ! ... Vsolute, R-space + Laue-rep.
      vpot = -rismt%vsr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_total (eV)', .FALSE., vpot)
      !
      vpol = -rismt%vlgz * RYTOEV  ! acting on electron
      CALL solvavg_add(solvavg_size(),     .FALSE., vpol, rismt%nrzl, .TRUE.)
      !
      ! ... Vsolv, Laue-rep.
      vpol = -rismt%vpot * RYTOEV  ! acting on electron
      CALL solvavg_add(solvavg_size(),     .FALSE., vpol, rismt%nrzl, .TRUE.)
      !
      DEALLOCATE(vpot)
      DEALLOCATE(vpol)
      !
    END IF
    !
  END SUBROUTINE put_vtotal
  !
  SUBROUTINE put_solute()
    IMPLICIT NONE
    !
    REAL(DP),    ALLOCATABLE :: vpot(:)
    COMPLEX(DP), ALLOCATABLE :: vpol(:)
    !
    IF (rismt%nr < 1 .OR. (rismt%nrzl * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF (my_group_id == io_group_id) THEN
      !
      ALLOCATE(vpot(rismt%nr))
      ALLOCATE(vpol(rismt%ngxy * rismt%nrzl))
#if defined (__DEBUG_RISM)
      !
      ! ... Vshort, R-space
      vpot = -rismt%vsr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_short (eV)' , .FALSE., vpot)
      !
      ! ... Vlong, R-space
      vpot = -rismt%vlr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_Rlong (eV)' , .FALSE., vpot)
      !
      !
      ! ... Vlong, Laue-rep.
      vpol = -rismt%vlgz * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_long (eV)',   .FALSE., vpol, rismt%nrzl, .TRUE.)
      CALL solvavg_put('G=2 v_long (eV)',   .FALSE., vpol, rismt%nrzl, .TRUE., 2)
#endif
      !
      ! ... Vsolute, R-space + Laue-rep.
      vpot = -rismt%vsr * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_solute (eV)', .FALSE., vpot)
      !
      vpol = -rismt%vlgz * RYTOEV  ! acting on electron
      CALL solvavg_add(solvavg_size(),      .FALSE., vpol, rismt%nrzl, .TRUE.)
      !
      DEALLOCATE(vpot)
      DEALLOCATE(vpol)
      !
    END IF
    !
  END SUBROUTINE put_solute
  !
  SUBROUTINE put_solvent()
    IMPLICIT NONE
    !
    COMPLEX(DP), ALLOCATABLE :: tmpl(:)
    !
    IF ((rismt%nrzl * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF (my_group_id == io_group_id) THEN
      !
      ALLOCATE(tmpl(rismt%ngxy * rismt%nrzl))
      !
      ! ... Rho, Laue-rep.
      tmpl = rismt%rhog / BOHR_RADIUS_ANGS
      CALL solvavg_put('Tot chg (e/A)', .TRUE.,  tmpl, rismt%nrzl, .TRUE.)
#if defined (__DEBUG_RISM)
      CALL solvavg_put('G=2 chg (e/A)', .TRUE.,  tmpl, rismt%nrzl, .TRUE., 2)
#endif
      !
      ! ... Vsolv, Laue-rep.
      tmpl = -rismt%vpot * RYTOEV  ! acting on electron
      CALL solvavg_put('Avg v_solvent (eV)',    .FALSE., tmpl, rismt%nrzl, .TRUE.)
#if defined (__DEBUG_RISM)
      CALL solvavg_put('G=2 v_solvent (eV)',    .FALSE., tmpl, rismt%nrzl, .TRUE., 2)
#endif
      !
      DEALLOCATE(tmpl)
      !
    END IF
    !
  END SUBROUTINE put_solvent
  !
  SUBROUTINE put_solvent_pbc()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: ir
    INTEGER                  :: ig
    COMPLEX(DP), ALLOCATABLE :: auxs(:)
    REAL(DP),    ALLOCATABLE :: rhor(:)
    REAL(DP),    ALLOCATABLE :: vpot(:)
    !
    IF (rismt%ng < 1) THEN
      RETURN
    END IF
    !
    IF (my_group_id == io_group_id) THEN
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        ALLOCATE(auxs(rismt%cfft%dfftt%nnr))
        ALLOCATE(rhor(rismt%cfft%dfftt%nnr))
        ALLOCATE(vpot(rismt%cfft%dfftt%nnr))
      END IF
      !
      ! ... Rho, G-space -> R-space
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        auxs = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      DO ig = 1, rismt%cfft%ngmt
        auxs(rismt%cfft%nlt(ig)) = rismt%rhog_pbc(ig)
      END DO
      IF (gamma_only) THEN
        DO ig = rismt%cfft%gstart_t, rismt%cfft%ngmt
          auxs(rismt%cfft%nltm(ig)) = CONJG(auxs(rismt%cfft%nlt(ig)))
        END DO
      END IF
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL invfft('Custom', auxs, rismt%cfft%dfftt)
      END IF
      !
      DO ir = 1, rismt%cfft%dfftt%nnr
        rhor(ir) = DBLE(auxs(ir)) / BOHR_RADIUS_ANGS
      END DO
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL solvavg_put('Tot chgPBC (e/A)', .TRUE., rhor)
      END IF
      !
      ! ... Vsolv, G-space -> R-space
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        auxs = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      DO ig = 1, rismt%cfft%ngmt
        auxs(rismt%cfft%nlt(ig)) = rismt%vpot_pbc(ig)
      END DO
      IF (gamma_only) THEN
        DO ig = rismt%cfft%gstart_t, rismt%cfft%ngmt
          auxs(rismt%cfft%nltm(ig)) = CONJG(auxs(rismt%cfft%nlt(ig)))
        END DO
      END IF
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL invfft('Custom', auxs, rismt%cfft%dfftt)
      END IF
      !
      DO ir = 1, rismt%cfft%dfftt%nnr
        vpot(ir) = DBLE(auxs(ir)) * RYTOEV
      END DO
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL solvavg_put('Avg v_solvPBC (eV)', .FALSE., vpot)
      END IF
      !
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        DEALLOCATE(auxs)
        DEALLOCATE(rhor)
        DEALLOCATE(vpot)
      END IF
      !
    END IF
    !
#endif
  END SUBROUTINE put_solvent_pbc
  !
  SUBROUTINE put_solvent_g()
    IMPLICIT NONE
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iiq
    INTEGER                  :: nv
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    INTEGER                  :: iz
    INTEGER                  :: iiz
    INTEGER                  :: igxy
    INTEGER                  :: jgxy
    INTEGER                  :: kgxy
    REAL(DP)                 :: rhov_right
    REAL(DP)                 :: rhov_left
    REAL(DP),    ALLOCATABLE :: rhor(:)
    COMPLEX(DP), ALLOCATABLE :: rhol(:)
    COMPLEX(DP), ALLOCATABLE :: ggz(:,:)
    !
    IF ((rismt%nrzs * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF ((rismt%nrzl * rismt%ngxy) < 1) THEN
      RETURN
    END IF
#if defined (__DEBUG_RISM)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
#endif
    !
    nq = get_nuniq_in_solVs()
    !
    IF (rismt%nsite > 0) THEN
      ALLOCATE(ggz(rismt%nrzs * rismt%ngxy, rismt%nsite))
    END IF
    ALLOCATE(rhol(rismt%nrzl * rismt%ngxy))
#if defined (__DEBUG_RISM)
    ALLOCATE(rhor(rismt%nr))
#endif
    !
    ! ... gr -> ggz
    DO iq = rismt%mp_site%isite_start, rismt%mp_site%isite_end
      iiq = iq - rismt%mp_site%isite_start + 1
      ggz(:, iiq) = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      IF (rismt%cfft%dfftt%nnr > 0) THEN
        CALL fw_lauefft_2xy(rismt%lfft, rismt%gr(:, iiq), ggz(:, iiq), rismt%nrzs, 1)
      END IF
    END DO
    !
    ! ... Guv, Laue-rep.
    DO iq = 1, nq
      iv         = iuniq_to_isite(1, iq)
      nv         = iuniq_to_nsite(iq)
      isolV      = isite_to_isolV(iv)
      iatom      = isite_to_iatom(iv)
      rhov_right = solVs(isolV)%density
      rhov_left  = solVs(isolV)%subdensity
      satom      = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        iiq = iq - rismt%mp_site%isite_start + 1
        !
        rhol = rismt%hsgz(:, iq - rismt%mp_site%isite_start + 1) &
           & + rismt%hlgz(:, iq - rismt%mp_site%isite_start + 1)
        IF (rismt%lfft%gxystart > 1) THEN
          rhol(1:rismt%nrzl) = rhol(1:rismt%nrzl) + CMPLX(1.0_DP, 0.0_DP, kind=DP)
        END IF
        !
        DO igxy = 1, rismt%ngxy
          jgxy = (igxy - 1) * rismt%nrzl
          kgxy = (igxy - 1) * rismt%nrzs
          DO iz = rismt%lfft%izcell_start, rismt%lfft%izcell_end
            iiz = iz - rismt%lfft%izcell_start + 1
            rhol(iz + jgxy) = ggz(iiz + kgxy, iiq)
          END DO
        END DO
        !
        DO igxy = 1, rismt%ngxy
          jgxy = (igxy - 1) * rismt%nrzl
          DO iz = 1, rismt%lfft%izleft_end
            rhol(iz + jgxy) = rhol(iz + jgxy) * rhov_left
          END DO
          DO iz = rismt%lfft%izright_start, rismt%lfft%nrz
            rhol(iz + jgxy) = rhol(iz + jgxy) * rhov_right
          END DO
        END DO
        !
        rhol = rhol * (DBLE(nv) / BOHR_RADIUS_ANGS)
        !
      ELSE
        owner_group_id = 0
        rhol = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhol, rhol, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Tot rho_'// TRIM(satom) //' (1/A)', .TRUE., rhol, rismt%nrzl, .TRUE.)
#if defined (__DEBUG_RISM)
        CALL solvavg_put('G=2 rho_'// TRIM(satom) //' (1/A)', .TRUE., rhol, rismt%nrzl, .TRUE., 2)
#endif
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
#if defined (__DEBUG_RISM)
    !
    ! ... Guv, R-space. (in unit-cell)
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhor = rismt%gr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg gUC_'// TRIM(satom), .FALSE., rhor)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
#endif
    !
    IF (rismt%nsite > 0) THEN
      DEALLOCATE(ggz)
    END IF
    DEALLOCATE(rhol)
#if defined (__DEBUG_RISM)
    DEALLOCATE(rhor)
#endif
    !
  END SUBROUTINE put_solvent_g
  !
  SUBROUTINE put_solvent_h()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP),    ALLOCATABLE :: rhor(:)
    COMPLEX(DP), ALLOCATABLE :: rhol(:)
    COMPLEX(DP), ALLOCATABLE :: rhos(:)
    !
    IF ((rismt%nrzl * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF ((rismt%nrzs * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(rhol(rismt%nrzl * rismt%ngxy))
    ALLOCATE(rhos(rismt%nrzs * rismt%ngxy))
    ALLOCATE(rhor(rismt%nr))
    !
    ! ... Hsuv, Laue-rep.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhol = rismt%hsgz(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhol = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhol, rhol, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg hs_'// TRIM(satom), .FALSE., rhol, rismt%nrzl, .TRUE.)
        CALL solvavg_put('G=2 hs_'// TRIM(satom), .FALSE., rhol, rismt%nrzl, .TRUE., 2)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Hluv, Laue-rep.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhol = rismt%hlgz(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhol = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhol, rhol, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg hl_'// TRIM(satom), .FALSE., rhol, rismt%nrzl, .TRUE.)
        CALL solvavg_put('G=2 hl_'// TRIM(satom), .FALSE., rhol, rismt%nrzl, .TRUE., 2)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Huv, Laue-rep.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhol = rismt%hsgz(:, iq - rismt%mp_site%isite_start + 1) &
           & + rismt%hlgz(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhol = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhol, rhol, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg h_'// TRIM(satom), .FALSE., rhol, rismt%nrzl, .TRUE.)
        CALL solvavg_put('G=2 h_'// TRIM(satom), .FALSE., rhol, rismt%nrzl, .TRUE., 2)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Huv, R-space. (in unit-cell)
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhor = rismt%hr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg hUC(R)_'// TRIM(satom), .FALSE., rhor)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Huv, Laue-rep. (in unit-cell)
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhos = rismt%hgz(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhos = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhos, rhos, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg hUC(L)_'// TRIM(satom), .FALSE., rhos, rismt%nrzs, .FALSE.)
        CALL solvavg_put('G=2 hUC(L)_'// TRIM(satom), .FALSE., rhos, rismt%nrzs, .FALSE., 2)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(rhol)
    DEALLOCATE(rhos)
    DEALLOCATE(rhor)
    !
#endif
  END SUBROUTINE put_solvent_h
  !
  SUBROUTINE put_solvent_c()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq, iq2
    INTEGER                  :: iiq
    INTEGER                  :: iv, iv2
    INTEGER                  :: iw, iw2
    INTEGER                  :: ivv
    INTEGER                  :: nv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    INTEGER                  :: iz
    INTEGER                  :: iiz
    INTEGER                  :: izsta
    INTEGER                  :: izend
    INTEGER                  :: izsol
    INTEGER                  :: isolvavg
    REAL(DP)                 :: qv
    REAL(DP)                 :: voppo
    REAL(DP)                 :: c2, d2
    REAL(DP)                 :: x12
    REAL(DP)                 :: z
    REAL(DP)                 :: zstep
    REAL(DP)                 :: zoffs
    REAL(DP)                 :: zedge
    REAL(DP)                 :: rhov_right
    REAL(DP)                 :: rhov_left
    REAL(DP),    ALLOCATABLE :: rhor(:)
    REAL(DP),    ALLOCATABLE :: rhor2(:)
    COMPLEX(DP), ALLOCATABLE :: rhol(:)
    COMPLEX(DP), ALLOCATABLE :: rhol2(:)
    COMPLEX(DP), ALLOCATABLE :: rhos(:)
    !
    IF ((rismt%nrzl * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF ((rismt%nrzs * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(rhol( rismt%nrzl * rismt%ngxy))
    ALLOCATE(rhol2(rismt%nrzl * rismt%ngxy))
    ALLOCATE(rhos( rismt%nrzs * rismt%ngxy))
    ALLOCATE(rhor( rismt%nr))
    ALLOCATE(rhor2(rismt%nr))
    !
    ! ... Csuv, R-space.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhor = rismt%csr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg cs_'// TRIM(satom), .FALSE., rhor)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Csuv, Laue-rep. (in unit-cell)
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        rhos = rismt%csgz(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        rhos = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhos, rhos, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg cs(L)_'// TRIM(satom), .FALSE., rhos, rismt%nrzs, .FALSE.)
        CALL solvavg_put('G=2 cs(L)_'// TRIM(satom), .FALSE., rhos, rismt%nrzs, .FALSE., 2)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Cuv, R-space + Laue-rep.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      qv    = solVs(isolV)%charge(iatom)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        iiq = iq - rismt%mp_site%isite_start + 1
        !
        rhor = rismt%csr(:, iiq)
        rhol = (-beta * qv) * rismt%vlgz(:)
        !
        IF (rismt%lfft%gxystart > 1) THEN
          !
          IF (rismt%lfft%xright .AND. rismt%lfft%xleft) THEN
            izsta = 1
            izend = 0
            !
          ELSE IF (rismt%lfft%xright) THEN
            izsta = 1
            izend = rismt%lfft%izright_start - 1
            izsol = rismt%lfft%izright_start
            voppo = DBLE(rismt%vleft(1))
            !
          ELSE !IF (rismt%lfft%xleft) THEN
            izsta = rismt%lfft%izleft_end + 1
            izend = rismt%lfft%nrz
            izsol = rismt%lfft%izleft_end
            voppo = DBLE(rismt%vright(1))
          END IF
          !
          IF (izsta <= izend) THEN
            iiz = izsol - rismt%lfft%izcell_start + 1
            c2  = DBLE(rismt%csgz(iiz, iiq)) - beta * qv * DBLE(rismt%vlgz(izsol))
            d2  = -beta * qv * voppo
            !
            zstep = rismt%lfft%zstep
            zoffs = (rismt%lfft%zleft + rismt%lfft%zoffset)
            zedge = zoffs + zstep * DBLE(izsol - 1)
            !
            DO iz = izsta, izend
              z = zoffs + zstep * DBLE(iz - 1)
              rhol(iz) = CMPLX(c2 + d2 * (z - zedge), 0.0_DP, kind=DP)
            END DO
          END IF
          !
        END IF
        !
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
        rhol = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhol, rhol, my_group_id, io_group_id, &
                & owner_group_id, iq + nq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg c_'// TRIM(satom), .FALSE., rhor)
        CALL solvavg_add(solvavg_size(),         .FALSE., rhol, rismt%nrzl, .TRUE.)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Cuv * Xvv(G=0), R-space + Laue-rep.
    IF (my_group_id == io_group_id) THEN
      rhor     = 0.0_DP
      isolvavg = solvavg_size()
      !
      DO iq = 1, nq
        iv    = iuniq_to_isite(1, iq)
        isolV = isite_to_isolV(iv)
        iatom = isite_to_iatom(iv)
        satom = ADJUSTL(solVs(isolV)%aname(iatom))
        CALL solvavg_put('Avg cx_'// TRIM(satom), .FALSE., rhor)
      END DO
    END IF
    !
    CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    !
    DO iq = 1, nq
      iv         = iuniq_to_isite(1, iq)
      nv         = iuniq_to_nsite(iq)
      isolV      = isite_to_isolV(iv)
      iatom      = isite_to_iatom(iv)
      qv         = solVs(isolV)%charge(iatom)
      rhov_right = solVs(isolV)%density
      rhov_left  = solVs(isolV)%subdensity
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        iiq = iq - rismt%mp_site%isite_start + 1
        !
        rhor = rismt%csr(:, iiq)
        rhol = (-beta * qv) * rismt%vlgz(:)
        !
        IF (rismt%lfft%gxystart > 1) THEN
          !
          IF (rismt%lfft%xright .AND. rismt%lfft%xleft) THEN
            izsta = 1
            izend = 0
            !
          ELSE IF (rismt%lfft%xright) THEN
            izsta = 1
            izend = rismt%lfft%izright_start - 1
            izsol = rismt%lfft%izright_start
            voppo = DBLE(rismt%vleft(1))
            !
          ELSE !IF (rismt%lfft%xleft) THEN
            izsta = rismt%lfft%izleft_end + 1
            izend = rismt%lfft%nrz
            izsol = rismt%lfft%izleft_end
            voppo = DBLE(rismt%vright(1))
          END IF
          !
          IF (izsta <= izend) THEN
            iiz = izsol - rismt%lfft%izcell_start + 1
            c2  = DBLE(rismt%csgz(iiz, iiq)) - beta * qv * DBLE(rismt%vlgz(izsol))
            d2  = -beta * qv * voppo
            !
            zstep = rismt%lfft%zstep
            zoffs = (rismt%lfft%zleft + rismt%lfft%zoffset)
            zedge = zoffs + zstep * DBLE(izsol - 1)
            !
            DO iz = izsta, izend
              z = zoffs + zstep * DBLE(iz - 1)
              rhol(iz) = CMPLX(c2 + d2 * (z - zedge), 0.0_DP, kind=DP)
            END DO
          END IF
          !
        END IF
        !
      ELSE
        owner_group_id = 0
        rhor = 0.0_DP
        rhol = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhor, rhor, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(rhol, rhol, my_group_id, io_group_id, &
                & owner_group_id, iq + nq, rismt%mp_site%inter_sitg_comm)
      !
      DO iq2 = 1, nq
        iv2 = iuniq_to_isite(1, iq2)
        iw  = MAX(iv, iv2)
        iw2 = MIN(iv, iv2)
        ivv = iw * (iw - 1) / 2 + iw2
        !
        x12 = 0.0_DP
        IF (rism1t%is_intra .AND. rism1t%mp_task%ivec_start == 1) THEN
          x12 = rism1t%wg(1, ivv) + rhov_right * rism1t%hg(1, ivv)
          !x12 = rism1t%wg(1, ivv) + rhov_left  * rism1t%hg(1, ivv)
        END IF
        CALL mp_sum(x12, rismt%intra_comm)
        !
        rhor2 = rhor * (DBLE(nv) * x12)
        rhol2 = rhol * (DBLE(nv) * x12)
        !
        IF (my_group_id == io_group_id) THEN
          CALL solvavg_add(isolvavg + iq2, .FALSE., rhor2)
          CALL solvavg_add(isolvavg + iq2, .FALSE., rhol2, rismt%nrzl, .TRUE.)
        END IF
      END DO
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(rhol)
    DEALLOCATE(rhol2)
    DEALLOCATE(rhos)
    DEALLOCATE(rhor)
    DEALLOCATE(rhor2)
    !
#endif
  END SUBROUTINE put_solvent_c
  !
  SUBROUTINE put_solvent_u()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP)                 :: qv
    REAL(DP),    ALLOCATABLE :: vpot(:)
    COMPLEX(DP), ALLOCATABLE :: vpol(:)
    !
    IF ((rismt%nrzl * rismt%ngxy) < 1) THEN
      RETURN
    END IF
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(vpol(rismt%nrzl * rismt%ngxy))
    ALLOCATE(vpot(rismt%nr))
    !
    ! ... Ulj, R-space.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = beta * rismt%uljr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg uLJ_'// TRIM(satom) // ' (kT)', .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Uwall, R-space.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = beta * rismt%uwr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg uW_'// TRIM(satom) // ' (kT)', .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    ! ... Uuv, R-space + Laue-rep.
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      qv    = solVs(isolV)%charge(iatom)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = beta * rismt%usr(:, iq - rismt%mp_site%isite_start + 1)
        vpol = (beta * qv) * rismt%vlgz(:)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
        vpol = CMPLX(0.0_DP, 0.0_DP, kind=DP)
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpol, vpol, my_group_id, io_group_id, &
                & owner_group_id, iq + nq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg u_'// TRIM(satom) // ' (kT)', .FALSE., vpot)
        CALL solvavg_add(solvavg_size(),                    .FALSE., vpol, rismt%nrzl, .TRUE.)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(vpol)
    DEALLOCATE(vpot)
    !
#endif
  END SUBROUTINE put_solvent_u
  !
  SUBROUTINE put_solvent_t()
    IMPLICIT NONE
#if defined (__DEBUG_RISM)
    !
    INTEGER                  :: nq
    INTEGER                  :: iq
    INTEGER                  :: iv
    INTEGER                  :: isolV
    INTEGER                  :: iatom
    CHARACTER(LEN=LEN_SATOM) :: satom
    INTEGER                  :: owner_group_id
    REAL(DP), ALLOCATABLE    :: vpot(:)
    !
    IF (rismt%nr < 1) THEN
      RETURN
    END IF
    !
    nq = get_nuniq_in_solVs()
    !
    ALLOCATE(vpot(rismt%nr))
    !
    ! ... -beta * Uuv + Huv - Cuv, R-space
    DO iq = 1, nq
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      satom = ADJUSTL(solVs(isolV)%aname(iatom))
      !
      IF (rismt%mp_site%isite_start <= iq .AND. iq <= rismt%mp_site%isite_end) THEN
        owner_group_id = my_group_id
        vpot = -beta * rismt%usr(:, iq - rismt%mp_site%isite_start + 1) &
                   & + rismt%hr (:, iq - rismt%mp_site%isite_start + 1) &
                   & - rismt%csr(:, iq - rismt%mp_site%isite_start + 1)
      ELSE
        owner_group_id = 0
        vpot = 0.0_DP
      END IF
      !
      CALL mp_sum(owner_group_id, rismt%mp_site%inter_sitg_comm)
      CALL mp_get(vpot, vpot, my_group_id, io_group_id, &
                & owner_group_id, iq, rismt%mp_site%inter_sitg_comm)
      !
      IF (my_group_id == io_group_id) THEN
        CALL solvavg_put('Avg t_'// TRIM(satom), .FALSE., vpot)
      END IF
      !
      CALL mp_barrier(rismt%mp_site%inter_sitg_comm)
    END DO
    !
    DEALLOCATE(vpot)
    !
#endif
  END SUBROUTINE put_solvent_t
  !
END SUBROUTINE print_solvavg_lauerism
