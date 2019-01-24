module tallyAdmin_class

  use numPrecision
  use tallyCodes
  use genericProcedures,      only : fatalError, charCmp
  use dictionary_class,       only : dictionary
  use dynArray_class,         only : dynIntArray
  use charMap_class,          only : charMap
  use particle_class,         only : particle, phaseCoord
  use particleDungeon_class,  only : particleDungeon
  use tallyClerk_inter,       only : tallyClerk
  use tallyClerkSlot_class,   only : tallyClerkSlot
  use scoreMemory_class,      only : scoreMemory
  use outputFile_class,       only : outputFile

  implicit none
  private


  !! Parameters
  integer(longInt), parameter :: NO_NORM = -17_longInt



  !!
  !! TallyAdmin is responsible for:
  !!   1) Routing event reports to all tallyClerk that accept them
  !!   2) Performing normalisation of results
  !!   3) Printing selected results to screen to monitor calculation progress
  !!   4) Returning tallyResult objects from selected clerks for interaction with
  !!      Physics packages
  !!   5) Printing all results to a file at the end of calculation
  !!
  !!
  !! SAMPLE DICTIOANRY INPUT:
  !!
  !! mytallyAdmin {
  !!   #display (clerk2 clerk1); #
  !!   #norm    clerk3;          #       ! Clerk should be size 1 (first bin of clerk is normalised)
  !!   #normVal 13.0;            #       ! Must be present if "norm" is present
  !!   #batchSize   4;           #       ! Default value 1
  !!   clerk1 { <clerk definition here> }
  !!   clerk2 { <clerk definition here> }
  !!   clerk3 { <clerk definition here> }
  !!   clerk4 { <clerk definition here> }
  !! }
  !!
  type, public :: tallyAdmin
    private
    ! Normalisation data
    integer(longInt)   :: normBinAddr  = NO_NORM
    real(defReal)      :: normValue
    character(nameLen) :: normClerkName

    ! Clerks and clerks name map
    type(tallyClerkSlot),dimension(:),allocatable :: tallyClerks
    type(charMap)                                 :: clerksNameMap

    ! Lists of Clerks to be executed for each report
    type(dynIntArray)  :: inCollClerks
    type(dynIntArray)  :: outCollClerks
    type(dynIntArray)  :: pathClerks
    type(dynIntArray)  :: transClerks
    type(dynIntArray)  :: histClerks
    type(dynIntArray)  :: cycleStartClerks
    type(dynIntArray)  :: cycleEndClerks

    ! List of clerks to display
    type(dynIntArray)  :: displayList

    ! Score memory
    type(scoreMemory)  :: mem
  contains

    ! Build procedures
    procedure :: init
    procedure :: kill

    ! Report Interface
    procedure :: reportInColl
    procedure :: reportOutColl
    procedure :: reportPath
    procedure :: reportTrans
    procedure :: reportHist
    procedure :: reportCycleStart
    procedure :: reportCycleEnd

    ! Display procedures
    procedure :: display

    ! Convergance check
    procedure :: isConverged

    ! File writing procedures
    procedure :: print

    procedure,private :: addToReports

  end type tallyAdmin

contains

  !!
  !! Initialise tallyAdmin form dictionary
  !!
  subroutine init(self,dict)
    class(tallyAdmin), intent(inout)            :: self
    class(dictionary), intent(in)               :: dict
    character(nameLen),dimension(:),allocatable :: names
    integer(shortInt)                           :: i, j, cyclesPerBatch
    integer(longInt)                            :: memSize, memLoc
    character(100), parameter :: Here ='init (tallyAdmin_class.f90)'

    ! Clean itself
    call self % kill()

    ! Obtain clerks dictionary names
    call dict % keysDict(names)

    ! Allocate space for clekrs
    allocate(self % tallyClerks(size(names)))

    ! Load clerks into slots and clerk names into map
    do i=1,size(names)
      call self % tallyClerks(i) % init(dict % getDictPtr(names(i)), names(i))
      call self % clerksNameMap % add(names(i),i)

    end do

    ! Register all clerks to recive their reports
    do i=1,size(self % tallyClerks)
      associate( reports => self % tallyClerks(i) % validReports() )
        do j=1,size(reports)
          call self % addToReports(reports(j), i)

        end do
      end associate
    end do

    ! Obtain names of clerks to display
    if( dict % isPresent('display')) then
      call dict % get(names,'display')
    end if

    ! Register all clerks to display
    do i=1,size(names)
      call self % displayList % add( self % clerksNameMap % get(names(i)))
    end do

    ! Read batching size
    call dict % getOrDefault(cyclesPerBatch,'batchSize',1)

    ! Initialise score memory
    ! Calculate required size.
    memSize = sum( self % tallyClerks % getSize() )
    call self % mem % init(memSize, 1, batchSize = cyclesPerBatch)

    ! Assign memory locations to the clerks
    memLoc = 1
    do i=1,size(self % tallyClerks)
      call self % tallyClerks(i) % setMemAddress(memLoc)
      memLoc = memLoc + self % tallyClerks(i) % getSize()

    end do

    ! Verify that final memLoc and memSize are consistant
    if(memLoc - 1 /= memSize) then
      call fatalError(Here, 'Memory addressing failed.')
    end if

    ! Read name of normalisation clerks if present
    if(dict % isPresent('norm')) then
      call dict % get(self % normClerkName,'norm')
      call dict % get(self % normValue,'normVal')
      i = self % clerksNameMap % get(self % normClerkName)
      self % normBinAddr = self % tallyClerks(i) % getMemAddress()
    end if

  end subroutine init

  !!
  !! Deallocates all content
  !!
  subroutine kill(self)
    class(tallyAdmin), intent(inout) :: self

    ! Kill clerks slots
    if(allocated(self % tallyClerks)) deallocate(self % tallyClerks)

    ! Kill processing lists
    call self % displayList % kill()

    call self % inCollClerks % kill()
    call self % outCollClerks % kill()
    call self % pathClerks % kill()
    call self % transClerks % kill()
    call self % histClerks % kill()
    call self % cycleStartClerks % kill()
    call self % cycleEndClerks % kill()

    ! Kill score memory
    call self % mem % kill()

  end subroutine kill

  !!
  !! Display convergance progress of selected tallies on the console
  !!
  subroutine display(self)
    class(tallyAdmin), intent(in) :: self
    integer(shortInt)             :: i
    integer(shortInt)             :: idx

    ! Go through all clerks marked as part of the display
    do i=1,self % displayList % getSize()
      idx = self % displayList % get(i)
      call self % tallyClerks(idx) % display(self % mem)

    end do

  end subroutine display

  !!
  !! Perform convergence check in selected clerks
  !! NOT IMPLEMENTED YET
  !!
  function isConverged(self) result(isIt)
    class(tallyAdmin), intent(in)    :: self
    logical(defBool)                 :: isIt
    integer(shortInt)                :: i,N

    isIt = .false.

  end function isConverged

  !!
  !! Add all results to outputfile
  !!
  subroutine print(self,output)
    class(tallyAdmin), intent(in)        :: self
    class(outputFile), intent(inout)     :: output
    integer(shortInt)                    :: i
    character(nameLen)                   :: name

    ! Print tallyAdmin settings
    name = 'batchSize'
    call output % printValue(self % mem % getBatchSize(), name)

    ! Print Clerk results
    do i=1,size(self % tallyClerks)
      call self % tallyClerks(i) % print(output, self % mem)
    end do

  end subroutine print

  !!
  !! Process incoming collision report
  !!
  subroutine reportInColl(self,p)
    class(tallyAdmin), intent(inout) :: self
    class(particle), intent(in)          :: p
    integer(shortInt)                    :: i, idx

    ! Go through all clerks that request the report
    do i=1,self % inCollClerks % getSize()
      idx = self % inCollClerks % get(i)
      call self % tallyClerks(idx) % reportInColl(p, self % mem)

    end do

  end subroutine reportInColl

  !!
  !! Process outgoing collision report
  !! Assume that pre is AFTER any implicit treatment (i.e. implicit capture)
  !!
  subroutine reportOutColl(self,p,MT,muL)
    class(tallyAdmin), intent(inout)      :: self
    class(particle), intent(in)           :: p
    integer(shortInt), intent(in)         :: MT
    real(defReal), intent(in)             :: muL
    integer(shortInt)                     :: i, idx

    ! Go through all clerks that request the report
    do i=1,self % outCollClerks % getSize()
      idx = self % outCollClerks % get(i)
      call self % tallyClerks(idx) % reportOutColl(p, MT, muL, self % mem)

    end do

  end subroutine reportOutColl

  !!
  !! Process pathlength report
  !! ASSUMPTIONS:
  !! Pathlength must be contained within a single cell and material
  !!
  subroutine reportPath(self,p,L)
    class(tallyAdmin), intent(inout)     :: self
    class(particle), intent(in)          :: p
    real(defReal), intent(in)            :: L
    integer(shortInt)                    :: i, idx

    ! Go through all clerks that request the report
    do i=1,self % pathClerks % getSize()
      idx = self % pathClerks % get(i)
      call self % tallyClerks(idx) % reportPath(p, L, self % mem)

    end do

  end subroutine reportPath

  !!
  !! Process transition report
  !! ASSUMPTIONS:
  !! Transition must be a straight line
  !! Pre and Post direction is assumed the same (aligned with r_pre -> r_post vector)
  !!
  subroutine reportTrans(self,p)
    class(tallyAdmin), intent(inout) :: self
    class(particle), intent(in)          :: p
    integer(shortInt)                    :: i, idx

    ! Go through all clerks that request the report
    do i=1,self % transClerks % getSize()
      idx = self % transClerks % get(i)
      call self % tallyClerks(idx) % reportTrans(p, self % mem)

    end do

  end subroutine reportTrans

  !!
  !! Process history report
  !! ASSUMPTIONS:
  !!
  subroutine reportHist(self,p)
    class(tallyAdmin), intent(inout)  :: self
    class(particle), intent(in)       :: p
    integer(shortInt)                 :: i, idx

    ! Go through all clerks that request the report
    do i=1,self % histClerks % getSize()
      idx = self % histClerks % get(i)
      call self % tallyClerks(idx) % reportHist(p, self % mem)

    end do


  end subroutine reportHist

  !!
  !! Process beginning of a cycle
  !!
  subroutine reportCycleStart(self,start)
    class(tallyAdmin), intent(inout)   :: self
    class(particleDungeon), intent(in) :: start
    integer(shortInt)                  :: i, idx

    ! Go through all clerks that request the report
    do i=1,self % cycleStartClerks % getSize()
      idx = self % cycleStartClerks % get(i)
      call self % tallyClerks(idx) % reportCycleStart(start, self % mem)

    end do

  end subroutine reportCycleStart

  !!
  !! Process end of the cycle
  !!
  subroutine reportCycleEnd(self,end)
    class(tallyAdmin), intent(inout)   :: self
    class(particleDungeon), intent(in) :: end
    integer(shortInt)                  :: i, idx
    real(defReal)                      :: normFactor, normScore
    character(100), parameter :: Here ='reportCycleEnd (tallyAdmin)class.f90)'

    ! Go through all clerks that request the report
    do i=1,self % cycleEndClerks % getSize()
      idx = self % cycleEndClerks % get(i)
      call self % tallyClerks(idx) % reportCycleEnd(end, self % mem)

    end do

    ! Calculate normalisation factor
    if( self % normBInAddr /= NO_NORM ) then
      normScore  = self % mem % getScore(self % normBinAddr)
      if (normScore == ZERO) then
        call fatalError(Here, 'Normalisation score from clerk:' // self % normClerkName // 'is 0')

      end if
      normFactor = self % normValue / normScore

    else
      normFactor = ONE
    end if

    ! Close cycle multipling all scores by multiplication factor
    call self % mem % closeCycle(normFactor)

  end subroutine reportCycleEnd

  !!
  !! Append sorrting array identified with the code with tallyClerk idx
  !!
  subroutine addToReports(self, reportCode, idx)
    class(tallyAdmin),intent(inout) :: self
    integer(shortInt), intent(in)   :: reportCode
    integer(shortInt), intent(in)   :: idx
    character(100),parameter  :: Here='addToReports (tallyAdmin_class.f90)'

    select case(reportCode)
      case(inColl_CODE)
        call self % inCollClerks % add(idx)

      case(outColl_CODE)
        call self % outCollClerks % add(idx)

      case(path_CODE)
        call self % pathClerks % add(idx)

      case(trans_CODE)
        call self % transClerks % add(idx)

      case(hist_CODE)
        call self % histClerks % add(idx)

      case(cycleStart_CODE)
        call self % cycleStartClerks % add(idx)

      case(cycleEnd_CODE)
        call self % cycleEndClerks % add(idx)

      case default
        call fatalError(Here, 'Undefined reportCode')
    end select

  end subroutine addToReports

    
end module tallyAdmin_class
