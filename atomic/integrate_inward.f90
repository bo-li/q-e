!
!----------------------------------------------------------------------
subroutine integrate_inward(e,mesh,ndm,dx,r,r2,sqr,f, &
     y,c,el,ik,nstart)
  !----------------------------------------------------------------------
  !
  !     this subroutine integrate inward the schroedinger equation
  !     only local potential allowed
  !
  use kinds, only : DP
  implicit none
  integer :: &
       mesh,  &    ! size of radial mesh
       ndm,   &    ! maximum radial mesh
       ik          ! the matching point

  real(kind=dp) :: &
       e,       &  ! output eigenvalue
       dx,      &  ! linear delta x for radial mesh
       r(mesh), &  ! radial mesh
       r2(mesh),&  ! square of radial mesh
       sqr(mesh),& ! square root of radial mesh
       f(mesh), &  ! the function defining the equation
       y(mesh), &  ! the output solution
       c(mesh),el(mesh) ! auxiliary space

  real(kind=dp) :: &
       rstart,  &  ! the starting r of the inward integration
       di,      &  ! auxiliary for integration  
       expn        ! exponential for tail of wavefunction

  integer :: &
       nstart, &   ! the starting point of inward integration
       n           ! counter on mesh points

  !
  !     prepare inward integration
  !     charlotte froese can j phys 41,1895(1963)
  !
  !     start at  min( rmax, 10*rmatch )
  !
  nstart=mesh
  rstart=10.0_dp*r(ik)
  if (rstart.lt.r(mesh)) then
     do n=ik,mesh
        nstart=n
        if(r(n).ge.rstart) go to 100
     enddo
100  if (mod(nstart,2) == 0) nstart=nstart+1
  endif
  !
  !  set up a, l, and c vectors
  !
  n=ik+1
  el(n)=10.0_dp*f(n)-12.0_dp
  c(n)=-f(ik)*y(ik)
  do n=ik+2,nstart
     di=10.0_dp*f(n)-12.0_dp
     el(n)=di-f(n)*f(n-1)/el(n-1)
     c(n)=-c(n-1)*f(n-1)/el(n-1)
  enddo
  !
  !  start inward integration by the froese's tail procedure
  !
  n=nstart-1
  expn=exp(-sqrt(12.0_dp*abs(1.0_dp-f(n))))
  y(n)=c(n)/(el(n)+f(nstart)*expn)
  y(nstart)=expn*y(n)
  !
  !    and integrate inward
  !
  do n=nstart-2,ik+1,-1
     y(n)=(c(n)-f(n+1)*y(n+1))/el(n)
  enddo

  return
end subroutine integrate_inward
