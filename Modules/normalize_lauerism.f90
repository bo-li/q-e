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
SUBROUTINE normalize_lauerism(rismt, charge, expand, ierr)
  !---------------------------------------------------------------------------
  !
  ! ... normalize total correlations to remove noise of solvent charge density,
  ! ... which is defined as
  !                   ----
  !        rho(gxy,z) >    q(v) * rho(v) * h(v; gxy,z)
  !                   ----
  !                     v
  !
  ! ... NOTE: h(gxy,z) is used, not g(gxy,z),
  ! ...       to obtain electrostatic consistent chemical potential of solvation.
  !
  ! ... Variables:
  ! ...   charge: total charge of solvent system
  ! ...   expand: use expand-cell(.TRUE.) or unit-cell(.FALSE.)
  !
  USE cell_base,      ONLY : at, alat
  USE constants,      ONLY : eps8
  USE err_rism,       ONLY : IERR_RISM_NULL, IERR_RISM_INCORRECT_DATA_TYPE
  USE kinds,          ONLY : DP
  USE mp,             ONLY : mp_sum
  USE rism,           ONLY : rism_type, ITYPE_LAUERISM
  USE solvmol,        ONLY : get_nuniq_in_solVs, solVs, iuniq_to_nsite, &
                           & iuniq_to_isite, isite_to_isolV, isite_to_iatom
  !
  IMPLICIT NONE
  !
  TYPE(rism_type), INTENT(INOUT) :: rismt
  REAL(DP),        INTENT(IN)    :: charge
  LOGICAL,         INTENT(IN)    :: expand
  INTEGER,         INTENT(OUT)   :: ierr
  !
  INTEGER               :: nq
  INTEGER               :: iq
  INTEGER               :: iiq
  INTEGER               :: iv
  INTEGER               :: nv
  INTEGER               :: isolV
  INTEGER               :: iatom
  INTEGER               :: irz
  INTEGER               :: iirz
  INTEGER               :: nright
  INTEGER               :: nleft
  INTEGER               :: igxy
  INTEGER               :: jgxy
  INTEGER               :: izright_tail
  INTEGER               :: izleft_tail
  REAL(DP)              :: rhov1
  REAL(DP)              :: rhov2
  REAL(DP)              :: qv
  REAL(DP)              :: qrho1
  REAL(DP)              :: qrho2
  REAL(DP)              :: vqrho
  REAL(DP)              :: dz
  REAL(DP)              :: area_xy
  REAL(DP)              :: dvol
  REAL(DP)              :: vol1
  REAL(DP)              :: vol2
  REAL(DP)              :: charge0
  REAL(DP)              :: chgtmp
  REAL(DP)              :: hr0
  REAL(DP)              :: hr1
  REAL(DP)              :: hr2
  REAL(DP), ALLOCATABLE :: rhoz(:)
  !
  INTEGER,     PARAMETER :: RHOZ_NEDGE     = 3  ! to avoid noise at edges of unit-cell
  REAL(DP),    PARAMETER :: RHOZ_THRESHOLD = 1.0E-5_DP
  COMPLEX(DP), PARAMETER :: C_ZERO = CMPLX(0.0_DP, 0.0_DP, kind=DP)
  !
  ! ... number of sites in solvents
  nq = get_nuniq_in_solVs()
  !
  ! ... check data type
  IF (rismt%itype /= ITYPE_LAUERISM) THEN
    ierr = IERR_RISM_INCORRECT_DATA_TYPE
    RETURN
  END IF
  !
  IF (rismt%mp_site%nsite < nq) THEN
    ierr = IERR_RISM_INCORRECT_DATA_TYPE
    RETURN
  END IF
  !
  IF (rismt%nrzs < rismt%cfft%dfftt%nr3) THEN
    ierr = IERR_RISM_INCORRECT_DATA_TYPE
    RETURN
  END IF
  !
  IF (rismt%nrzl < rismt%lfft%nrz) THEN
    ierr = IERR_RISM_INCORRECT_DATA_TYPE
    RETURN
  END IF
  !
  IF (rismt%nr < rismt%cfft%dfftt%nnr) THEN
    ierr = IERR_RISM_INCORRECT_DATA_TYPE
    RETURN
  END IF
  !
  ! ... allocate memory
  IF (rismt%nrzl > 0) THEN
    ALLOCATE(rhoz(rismt%nrzl))
  END IF
  !
  ! ... set variables
  dz      = rismt%lfft%zstep * alat
  area_xy = ABS(at(1, 1) * at(2, 2) - at(1, 2) * at(2, 1)) * alat * alat
  dvol    = area_xy * dz
  !
  ! ... qrho = sum(qv^2 * rhov^2)
  qrho1 = 0.0_DP
  qrho2 = 0.0_DP
  !
  DO iq = rismt%mp_site%isite_start, rismt%mp_site%isite_end
    iiq   = iq - rismt%mp_site%isite_start + 1
    iv    = iuniq_to_isite(1, iq)
    nv    = iuniq_to_nsite(iq)
    isolV = isite_to_isolV(iv)
    iatom = isite_to_iatom(iv)
    rhov1 = solVs(isolV)%density
    rhov2 = solVs(isolV)%subdensity
    qv    = solVs(isolV)%charge(iatom)
    qrho1 = qrho1 + DBLE(nv) * qv * qv * rhov1 * rhov1
    qrho2 = qrho2 + DBLE(nv) * qv * qv * rhov2 * rhov2
  END DO
  !
  CALL mp_sum(qrho1, rismt%mp_site%inter_sitg_comm)
  CALL mp_sum(qrho2, rismt%mp_site%inter_sitg_comm)
  !
  ! ... rhoz: planar average of rho(r), in expand-cell
  IF (rismt%nrzl > 0) THEN
    rhoz(:) = 0.0_DP
  END IF
  !
  DO iq = rismt%mp_site%isite_start, rismt%mp_site%isite_end
    iiq   = iq - rismt%mp_site%isite_start + 1
    iv    = iuniq_to_isite(1, iq)
    nv    = iuniq_to_nsite(iq)
    isolV = isite_to_isolV(iv)
    iatom = isite_to_iatom(iv)
    rhov1 = DBLE(nv) * solVs(isolV)%density
    rhov2 = DBLE(nv) * solVs(isolV)%subdensity
    qv    = solVs(isolV)%charge(iatom)
    !
    IF (rismt%lfft%gxystart > 1) THEN
      !
!$omp parallel do default(shared) private(irz)
      DO irz = 1, rismt%lfft%izleft_gedge
        rhoz(irz) = rhoz(irz) + qv * rhov2 * DBLE(rismt%hsgz(irz, iiq) + rismt%hlgz(irz, iiq))
      END DO
!$omp end parallel do
      !
!$omp parallel do default(shared) private(irz)
      DO irz = rismt%lfft%izright_gedge, rismt%lfft%nrz
        rhoz(irz) = rhoz(irz) + qv * rhov1 * DBLE(rismt%hsgz(irz, iiq) + rismt%hlgz(irz, iiq))
      END DO
!$omp end parallel do
      !
    END IF
  END DO
  !
  IF (rismt%nrzl > 0) THEN
    CALL mp_sum(rhoz, rismt%mp_site%inter_sitg_comm)
  END IF
  !
  ! ... truncate rhoz
  charge0 = 0.0_DP
  izright_tail = 0
  izleft_tail  = 0
  !
  IF (rismt%lfft%gxystart > 1) THEN
    izleft_tail = 1
    DO irz = 1, rismt%lfft%izleft_gedge
      IF (ABS(rhoz(irz)) < RHOZ_THRESHOLD .OR. &
      &   ABS(irz - rismt%lfft%izcell_start) <= RHOZ_NEDGE) THEN
        rhoz(irz) = 0.0_DP
      ELSE
        izleft_tail = irz
        EXIT
      END IF
    END DO
    !
    izright_tail = rismt%lfft%nrz
    DO irz = rismt%lfft%izright_gedge, rismt%lfft%nrz
      iirz = rismt%lfft%nrz + rismt%lfft%izright_gedge - irz
      IF (ABS(rhoz(iirz)) < RHOZ_THRESHOLD .OR. &
      &   ABS(iirz - rismt%lfft%izcell_end) <= RHOZ_NEDGE) THEN
        rhoz(iirz) = 0.0_DP
      ELSE
        izright_tail = iirz
        EXIT
      END IF
    END DO
    !
    chgtmp = 0.0_DP
!$omp parallel do default(shared) private(irz) reduction(+:chgtmp)
    DO irz = izleft_tail, rismt%lfft%izleft_gedge
      chgtmp = chgtmp + dvol * rismt%rhog(irz)
    END DO
!$omp end parallel do
    charge0 = charge0 + chgtmp
    !
    chgtmp = 0.0_DP
!$omp parallel do default(shared) private(irz) reduction(+:chgtmp)
    DO irz = rismt%lfft%izright_gedge, izright_tail
      chgtmp = chgtmp + dvol * rismt%rhog(irz)
    END DO
!$omp end parallel do
    charge0 = charge0 + chgtmp
    !
  END IF
  !
  CALL mp_sum(charge0,      rismt%mp_site%intra_sitg_comm)
  CALL mp_sum(izright_tail, rismt%mp_site%intra_sitg_comm)
  CALL mp_sum(izleft_tail,  rismt%mp_site%intra_sitg_comm)
  !
  ! ... truncate hgz, hsgz, hlgz
  IF (rismt%nsite > 0) THEN
    !
    IF (expand) THEN ! expand-cell
      !
      DO igxy = 1, rismt%ngxy
        jgxy = (igxy - 1) * rismt%nrzl
        !
!$omp parallel do default(shared) private(irz)
        DO irz = 1, (izleft_tail - 1)
          rismt%hsgz(irz + jgxy, :) = C_ZERO
          rismt%hlgz(irz + jgxy, :) = C_ZERO
        END DO
!$omp end parallel do
        !
!$omp parallel do default(shared) private(irz)
        DO irz = (izright_tail + 1), rismt%lfft%nrz
          rismt%hsgz(irz + jgxy, :) = C_ZERO
          rismt%hlgz(irz + jgxy, :) = C_ZERO
        END DO
!$omp end parallel do
        !
      END DO
      !
    ELSE ! unit-cell
      !
      DO igxy = 1, rismt%ngxy
        jgxy = (igxy - 1) * rismt%nrzs
        !
        DO irz = rismt%lfft%izcell_start, (izleft_tail - 1)
          iirz = irz - rismt%lfft%izcell_start + 1
          rismt%hgz(iirz + jgxy, :) = C_ZERO
        END DO
        !
        DO irz = (izright_tail + 1), rismt%lfft%izcell_end
          iirz = irz - rismt%lfft%izcell_start + 1
          rismt%hgz(iirz + jgxy, :) = C_ZERO
        END DO
        !
      END DO
      !
    END IF
    !
  END IF
  !
  ! ... renormalize hgz, hsgz, hlgz
  IF (ABS(charge0 - charge) > eps8) THEN
    !
    nright = MAX(0, izright_tail - rismt%lfft%izright_gedge + 1)
    nleft  = MAX(0, rismt%lfft%izleft_gedge - izleft_tail + 1)
    vol1   = dvol * DBLE(nright)
    vol2   = dvol * DBLE(nleft)
    vqrho  = vol1 * qrho1 + vol2 * qrho2
    IF (ABS(vqrho) <= eps8) THEN  ! will not be occurred
      CALL errore('normalize_lauerism', 'vqrho is zero', 1)
    END IF
    hr0    = (charge0 - charge) / vqrho
    !
    DO iq = rismt%mp_site%isite_start, rismt%mp_site%isite_end
      iiq   = iq - rismt%mp_site%isite_start + 1
      iv    = iuniq_to_isite(1, iq)
      isolV = isite_to_isolV(iv)
      iatom = isite_to_iatom(iv)
      rhov1 = solVs(isolV)%density
      rhov2 = solVs(isolV)%subdensity
      qv    = solVs(isolV)%charge(iatom)
      hr1   = hr0 * qv * rhov1
      hr2   = hr0 * qv * rhov2
      !
      IF (rismt%lfft%gxystart > 1) THEN
        !
        IF (expand) THEN ! expand-cell
          !
!$omp parallel do default(shared) private(irz)
          DO irz = izleft_tail, rismt%lfft%izleft_gedge
            ! correct only short-range (for convenience)
            rismt%hsgz(irz, iiq) = rismt%hsgz(irz, iiq) - CMPLX(hr2, 0.0_DP, kind=DP)
          END DO
!$omp end parallel do
          !
!$omp parallel do default(shared) private(irz)
          DO irz = rismt%lfft%izright_gedge, izright_tail
            ! correct only short-range (for convenience)
            rismt%hsgz(irz, iiq) = rismt%hsgz(irz, iiq) - CMPLX(hr1, 0.0_DP, kind=DP)
          END DO
!$omp end parallel do
          !
        ELSE ! unit-cell
          !
          DO irz = rismt%lfft%izcell_start, rismt%lfft%izleft_gedge
            iirz = irz - rismt%lfft%izcell_start + 1
            rismt%hgz(iirz, iiq) = rismt%hgz(iirz, iiq) - CMPLX(hr2, 0.0_DP, kind=DP)
          END DO
          !
          DO irz = rismt%lfft%izright_gedge, rismt%lfft%izcell_end
            iirz = irz - rismt%lfft%izcell_start + 1
            rismt%hgz(iirz, iiq) = rismt%hgz(iirz, iiq) - CMPLX(hr1, 0.0_DP, kind=DP)
          END DO
          !
        END IF
        !
      END IF
      !
    END DO
    !
  END IF
  !
  ! ... normally done
  ierr = IERR_RISM_NULL
  !
  ! ... deallocate memory
100 CONTINUE
  IF (rismt%nrzl > 0) THEN
    DEALLOCATE(rhoz)
  END IF
  !
END SUBROUTINE normalize_lauerism
