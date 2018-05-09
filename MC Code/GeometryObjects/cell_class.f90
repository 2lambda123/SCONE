!
! The cell class is the basic geometrical structure: it contains either universes, lattices or materials
! This class will contains bounding surfaces and their halfspace and can be searched to identify
! whether a particle is inside the cell.
! There will be many repeated instances of cells with identical geometries but different locations
! and contents. These must be uniquely identified
!
module cell_class
  use numPrecision
  use genericProcedures, only : fatalError
  use universalVariables
  use surface_class
  use coord_class

  implicit none
  private

  type, public :: cell
    type(surface_ptr), dimension(:), allocatable :: surfaces            ! the surfaces which define the cell
    logical(defBool), dimension(:), allocatable  :: halfspaces          ! The halfspace of each surface corresponding to inside the cell
    integer(shortInt)                            :: numSurfaces         ! the number of surfaces which define the cell
    integer(shortInt)                            :: fillType = 0        ! determines if cell contains a material, universe, or lattice (1,2,3)
    integer(shortInt)                            :: latIdx = 0          ! index of the cell's lattice contents
    integer(shortInt)                            :: uniIdx = 0          ! index of the cell's universe contents
    integer(shortInt), dimension(:), allocatable :: matIdx = 0          ! index of the cell's material contents
    integer(longInt), dimension(:), allocatable  :: uniqueID            ! identifies unique instance of a cell
    real(defReal), dimension(:), allocatable     :: volume              ! the volume of the cell
    type(coordList), dimension(:), allocatable   :: location            ! co-ord locations of each cell
    integer(shortInt)                            :: id                  ! unique user-defined ID
    logical(defBool)                             :: insideGeom = .true. ! is cell within geometry? Used to invoke BCs
    integer(shortInt)                            :: instances = 1       ! the number of instances of a given cell
    integer(longInt)                             :: geometryIndex       ! index of the cell in the cell array
    character(100), public :: name = ""
  contains
    procedure :: init
    procedure :: setInstances
    procedure :: fill
    procedure :: insideCell
    procedure :: getDistance
    procedure :: whichSurface
    procedure :: coordCompare
  end type cell

  ! Wrapper type for cell pointers
  type, public :: cell_ptr
    class(cell), pointer :: ptr
  contains
    procedure :: init => init_ptr
    procedure :: setInstance => setInstances_ptr
    procedure :: fill => fill_ptr
    procedure :: insideCell => insideCell_ptr
    procedure :: getDistance => getDistance_ptr
    procedure :: whichSurface => whichSurface_ptr
    procedure :: coordCompare => coordCompare_ptr
    procedure :: insideGeom => insideGeom_ptr
    procedure :: fillType => fillType_ptr
    procedure :: uniIdx => uniIdx_ptr
    procedure :: latIdx => latIdx_ptr
    procedure :: matIdx => matIdx_ptr
    procedure :: geometryIdx => geometryIdx_ptr
    procedure :: associated => associated_ptr
    procedure :: name => name_ptr
    procedure :: kill
    generic   :: assignment(=) => cell_ptr_assignment, cell_ptr_assignment_target
    procedure,private :: cell_ptr_assignment
    procedure,private :: cell_ptr_assignment_target
    !procedure,private :: cell_ptr_assignment_null
  end type cell_ptr

contains

  !!
  !! Initialise the cell with the bounding surfaces, their halfspaces and parent universe
  !!
  subroutine init(self, surfaces, halfspaces, id, fillType, geometryIdx, name)
    class(cell), intent(inout)                   :: self
    class(surface_ptr), dimension(:), intent(in) :: surfaces
    logical(defBool), dimension(:), intent(in)   :: halfspaces
    integer(shortInt), intent(in)                :: id
    integer(shortInt), intent(in)                :: fillType
    integer(shortInt), intent(in)                :: geometryIdx
    character(*), optional, intent(in)           :: name

    self % numSurfaces = size(halfspaces)
    allocate(self % surfaces(self % numSurfaces))
    allocate(self % halfspaces(self % numSurfaces))
    self % surfaces = surfaces
    self % halfspaces = halfspaces
    self % id = id
    self % fillType = fillType
    self % geometryIdx = geometryIdx
    if (fillType == outsideFill) then
      self % insideGeom = .FALSE.
    end if
    if (present(name)) self % name = name

  end subroutine init

  !!
  !! Set the number of cell instances and provide unique ID(s) and location(s) for searching
  !!
  subroutine setInstances(self, ID, location)
    class(cell), intent(inout)                 :: self
    integer(longInt), intent(in), dimension(:) :: ID
    type(coordList), intent(in), dimension(:)  :: location

    self % instances = size(ID)
    if (self % fillType .NEQV. materialFill) then
      if (size(ID) > 1) then
        call fatalError('setInstances, cell',&
        'Only cells containing a material fill may have multiple instances')
      end if
    else
      allocate(self % matIdx(self % instances))
    end if

    allocate(self % uniqueID(self % instances))
    allocate(self % volume(self % instances))
    allocate(self % location(self % instances))
    self % uniqueID = ID
    self % location = location

  end subroutine setInstances

  !!
  !! Fills the cell with a material, universe or lattice
  !! If instance is not included, fills only the first instance
  !! If instance is present, must be filling a material
  !!
  subroutine fill(self, fillIdx, instance)
    class(cell), intent(inout)              :: self
    integer(shortInt), intent(in)           :: fillIdx
    integer(shortInt), intent(in), optional :: instance

    ! Instance only applies when filling with a material
    if (present(instance)) then
      if (self % fillType == materialFill) then
        self % materialIdx(instance) = fillIdx
      else
        call fatalError('fill, cell',&
        'When filling a cell, must only provide instances when filling material IDs')
      end if
    else
      ! Fill cell depending on given fill type
      if (self % fillType == materialFill) then
        self % materialIdx(1) = fillIdx
      else if (self % fillType == universeFill) then
        self % uniIdx = fillIdx
      else if (self % fillType == latticeFill) then
        self % latIdx = fillIdx
      else if (self % fillType /= outsideFill) then
        call fatalError('fill, cell', 'Cell filled with an incorrect fill index')
      end if
    end if
  end subroutine fill

  !!
  !! Checks whether a point occupies a cell by examining each surface in turn
  !! Returns TRUE if point is in cell, FALSE if point is not
  !!
  function insideCell(self, r, u) result(exists)
    class(cell), intent(in)                 :: self
    real(defReal), dimension(3), intent(in) :: r, &
                                               u
    logical(defBool)                        :: exists, &  ! whether point exists in cell
                                               sense      ! halfspace of surface in which point exists
    integer(shortInt)                       :: i

    ! Need only check that halfspaces are satisfied: if not, the point is outside the cell
    ! Check each surrounding surface of the cell to ensure point is within its halfspace
    do i = 1, self % numSurfaces
      exists = self % surfaces(i) % halfspace(r,u)
      sense = self % halfspaces(i)

      ! If not in halfspace, terminate the search
      if ( exists .NEQV. sense ) then
        exists = outside
        return
      end if
    end do
    exists = inside
    return

  end function insideCell

  !!
  !! Find the shortest positive distance to the boundary of the cell
  !!
  function getDistance(self, r, u) result(distance)
    class(cell), intent(in)                 :: self
    real(defReal), dimension(3), intent(in) :: r, u
    real(defReal)                           :: distance
    real(defReal)                           :: testDistance
    integer(shortInt)                       :: i

    distance = INFINITY

    ! Search through all surfaces to find the minimum distance to the boundary
    ! Should not have to check for negative distances: these are set to INFINITY
    ! in the distance routines
    do i = 1, self%numSurfaces
      testDistance = self % surfaces(i) % distanceToSurface(r,u)
      if (testDistance < distance) then
        distance = testDistance
      end if
    end do

  end function getDistance

  !!
  !! Find which surface of a cell was crossed by a particle
  !! For compound surfaces must return component surface
  !!
  function whichSurface(self, r, u)result(surfPointer)
    class(cell), intent(in)                 :: self
    real(defReal), dimension(3), intent(in) :: r, u
    class(surface), pointer                 :: surfPointer
    integer(shortInt)                       :: i
    real(defReal)                           :: distance, testDistance

    distance = INFINITY
    ! First identify which surface will have been crossed assuming all surfaces are simple
    do i = 1, self % numSurfaces
      testDistance = self % surfaces(i) % distanceToSurface(r,u)
      if (testDistance < distance) then
        distance = testDistance
        surfPointer => self % surfaces(i) % ptr
      end if
    end do

    ! If the identified surface is compound, identify which constituent surface is crossed
    if (surfPointer % isCompound) then
      surfPointer => surfPointer % whichSurface(r, u)
    end if

  end function whichSurface

  !!
  !! Given a co-ordinate list, compare with instances of a cell's location to find
  !! the instance index
  !! If the cell has only one instance then the index will be returned instantly as 1
  !!
  function coordCompare(self, location) result(idx)
    class(cell), intent(in) :: self
    type(coordList), intent(in) :: location
    integer(shortInt) :: idx
    integer(shortInt) :: i
    logical(defBool)  :: found

    if (self % instance == 1) then
      idx = 1
      return
    else
      ! Efficiently compare co-ordinates
      ! Presume all cell locations are unique!
      ! Branchless search - thanks for the good shout, Mikolaj!
      do i = 1, self % instances
        found = .TRUE.
        do n = 1, location % nesting
          found = found .AND. (location % lvl(n) % uniIdx == self % location(i) % lvl(n) % uniIdx)
          found = found .AND. (location % lvl(n) % uniIdx == self % location(i) % lvl(n) % latIdx)
          found = found .AND. (location % lvl(n) % uniIdx == self % location(i) % lvl(n) % ijkIdx)
          found = found .AND. (location % lvl(n) % uniIdx == self % location(i) % lvl(n) % cellIdx)
        end do
        if (found) return i
      end do
    end if

    call fatalError('coordCompare, cell','Could not find cell instance from the location provided')

  end function coordCompare

!!
!! Pointer wrapper functions
!!
  !!
  !! Initialise the cell with the bounding surfaces, their halfspaces and the
  !! indices describing the fill type, fill, and parent universe
  !!
  subroutine init_ptr(self, surfaces, halfspaces, id, fillType, geometryIdx, name)
    class(cell_ptr), intent(inout)               :: self
    class(surface_ptr), dimension(:), intent(in) :: surfaces
    logical(defBool), dimension(:), intent(in)   :: halfspaces
    integer(shortInt), intent(in)                :: id
    integer(shortInt), intent(in)                :: fillType
    integer(shortInt), intent(in)                :: geometryIdx
    character(100), optional, intent(in)         :: name
    call self % ptr % init(surfaces, halfspaces, id, fillType, geometryIdx, name)
  end subroutine init_ptr

  subroutine fill_ptr(self, fillIdx, instance)
    class(cell_ptr), intent(inout)          :: self
    integer(shortInt), intent(in)           :: fillIdx
    integer(shortInt), intent(in), optional :: instance
    call self % ptr % fill(fillIdx, instance)
  end subroutine fill_ptr

  !!
  !! Set the number of cell instances and provide unique ID(s) and location(s) for searching
  !!
  subroutine setInstances_ptr(self, ID, location)
    class(cell), intent(inout)                 :: self
    integer(longInt), intent(in), dimension(:) :: ID
    type(coordList), intent(in), dimension(:)  :: location
    call self % ptr % setInstances(ID, location)
  end subroutine setInstances_ptr

  !!
  !! Checks whether a point occupies a cell by examining each surface in turn
  !! Returns TRUE if point is in cell, FALSE if point is not
  !!
  function insideCell_ptr(self, r, u) result(exists)
    class(cell_ptr), intent(in)             :: self
    real(defReal), dimension(3), intent(in) :: r, u
    logical(defBool)                        :: exists
    exists = self % ptr % insideCell(r,u)
  end function insideCell_ptr

  !!
  !! Find the shortest positive distance to the boundary of the cell
  !!
  function getDistance_ptr(self, r, u) result(distance)
    class(cell_ptr), intent(in)             :: self
    real(defReal), dimension(3), intent(in) :: r, u
    real(defReal)                           :: distance
    distance = self % ptr % getDistance(r,u)
  end function getDistance_ptr

  !!
  !! Return whether cell_ptr points to a cell which is inside the geometry
  !!
  function insideGeom_ptr(self) result(insideGeom)
    class(cell_ptr), intent(in) :: self
    logical(defBool)            :: insideGeom
    insideGeom = self % ptr % insideGeom
  end function insideGeom_ptr

  !!
  !! Given a co-ordinate list, compare with instances of a cell's location to find
  !! the instance index
  !! If the cell has only one instance then the index will be returned instantly as 1
  !!
  function coordCompare_ptr(self, location) result(idx)
    class(cell), intent(in) :: self
    type(coordList), intent(in) :: location
    integer(shortInt) :: idx
    idx = self % ptr % coordCompare(location)
  end function coordCompare_ptr

  !!
  !! Returns the fill type of the cell pointed to by cell_ptr
  !!
  function fillType_ptr(self) result(fillType)
    class(cell_ptr), intent(in) :: self
    integer(shortInt)           :: fillType
    fillType = self % ptr % fillType
  end function fillType_ptr

  !!
  !! Returns the universe index of the cell pointed to by cell_ptr
  !!
  function uniIdx_ptr(self) result(uniIdx)
    class(cell_ptr), intent(in) :: self
    integer(shortInt)           :: uniIdx
    uniIdx = self % ptr % uniIdx
  end function uniIdx_ptr

  !!
  !! Returns the lattice index of the cell pointed to by cell_ptr
  !!
  function latIdx_ptr(self) result(latIdx)
    class(cell_ptr), intent(in) :: self
    integer(shortInt)           :: latIdx
    latIdx = self % ptr % latIdx
  end function latIdx_ptr

  !!
  !! Returns the material index of the cell pointed to by cell_ptr
  !! Must provide an index for multiple cells
  !!
  function matIdx_ptr(self, i) result(matIdx)
    class(cell_ptr), intent(in)   :: self
    integer(shortInt), intent(in) :: i
    integer(shortInt)             :: materialIdx
    matIdx = self % ptr % matIdx(i)
  end function matIdx_ptr

  !!
  !! Returns the geometry index of the cell pointed to by cell_ptr
  !!
  function geometryIdx_ptr(self) result(geometryIdx)
    class(cell_ptr), intent(in) :: self
    integer(shortInt)           :: geometryIdx
    geometryIdx = self % ptr % geometryIdx
  end function geometryIdx_ptr

  !!
  !! Check whether the pointer wrapper is associated to a cell
  !!
  function associated_ptr(self) result(assoc)
    class(cell_ptr), intent(in) :: self
    logical(defBool)            :: assoc
    assoc = associated(self % ptr)
  end function associated_ptr

  !!
  !! Returns the name of the cell pointed to by cell_ptr
  !!
  function name_ptr(self)result(name)
    class(cell_ptr), intent(in) :: self
    character(100)              :: name
    name = self % ptr % name
  end function name_ptr

  !!
  !! Find which surface of a cell was crossed by a particle
  !! For compound surfaces must return component surface
  !!
  function whichSurface_ptr(self, r, u) result(surfPointer)
    class(cell_ptr), intent(in)             :: self
    real(defReal), dimension(3), intent(in) :: r, u
    class(surface), pointer                 :: surfPointer
    surfPointer => self % ptr % whichSurface(r,u)
  end function whichSurface_ptr

  subroutine cell_ptr_assignment(LHS,RHS)
    class(cell_ptr), intent(out)  :: LHS
    type(cell_ptr), intent(in)    :: RHS

    !if(associated(LHS % ptr)) deallocate(LHS % ptr)
    LHS % ptr => RHS % ptr
  end subroutine cell_ptr_assignment

  subroutine cell_ptr_assignment_target(LHS,RHS)
    class(cell_ptr), intent(out)        :: LHS
    class(cell), target, intent(in)     :: RHS

    !if(associated(LHS % ptr)) deallocate(LHS % ptr)
    LHS % ptr => RHS

  end subroutine cell_ptr_assignment_target

  subroutine kill(self)
    class(cell_ptr), intent(inout) :: self
    self % ptr => null()
  end subroutine kill

end module cell_class