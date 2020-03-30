!############################################################################
! This routine is part of
! md_tian2 (Molecular Dynamics Tian Xia 2)
! (c) 2014-2020 Dan J. Auerbach, Svenja M. Janke, Marvin Kammler,
!               Sascha Kandratsenka, Sebastian Wille
! Dynamics at Surfaces Department
! MPI for Biophysical Chemistry Goettingen, Germany
! Georg-August-Universitaet Goettingen, Germany
!
! This program is free software: you can redistribute it and/or modify it
! under the terms of the GNU General Public License as published by the
! Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful, but
! WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
! or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
! for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program. If not, see http://www.gnu.org/licenses.
!############################################################################

module pes_nene_mod

    !md_tian2 related modules
    use constants, only : max_string_length, pes_id_nene, default_string, default_int, default_real, default_bool, dp
    use universe_mod

    ! RuNNer related modules (predict.f90)
    use fileunits
    use fittingoptions
    use globaloptions
    !use inputnncounters
    use mode1options
    use mpi_mod
    use nnconstants
    use nnewald
    use nnflags
    use nnshort_atomic
    !use nnshort_pair ! check if no full subroutine of RuNNer we use needs this subroutine!!
    use predictionoptions
    !use saturation
    !use structures -> maybe needed?
    use symfunctions
    use timings


    implicit none

    integer :: ielem
    integer :: iseed

    ! following all needed variable declarations not listed in any RuNNer related module
    logical :: lelement(102)
    integer :: ztemp

    integer, dimension(:)  , allocatable :: nodes_short_local
    integer, dimension(:)  , allocatable :: nodes_ewald_local
    integer, dimension(:)  , allocatable :: num_funcvalues_local
    integer, dimension(:)  , allocatable :: num_funcvaluese_local

    character(len=2) :: elementtemp, elementtemp1, elementtemp2, elementtemp3

    logical :: lfounddebug
    logical :: lfound_num_layersshort
    logical :: lfound_num_layersewald
    logical :: lfound_num_layerspair
    logical :: lfound_luseatomenergies
    logical :: lfound_luseatomcharges
    logical :: lfound_nelem
    logical :: lperiodic

    integer :: function_type_temp

    real(dp) :: funccutoff_local
    real(dp) :: maxcutoff_local

    integer :: max_num_pairs

    !integer  :: num_atoms
    real(dp) :: lattice(3,3)
    real(dp) :: xyzstruct(3,atoms%natoms)

    character(len=2) :: elementsymbol(atoms%natoms)

    integer  :: zelem(atoms%natoms)
    integer  :: num_pairs
    integer  :: num_atoms_element(nelem)
    real(dp) :: minvalue_short_atomic(nelem,maxnum_funcvalues_short_atomic)
    real(dp) :: maxvalue_short_atomic(nelem,maxnum_funcvalues_short_atomic)
    real(dp) :: avvalue_short_atomic(nelem,maxnum_funcvalues_short_atomic)
    real(dp) :: minvalue_elec(nelem,maxnum_funcvalues_elec)
    real(dp) :: maxvalue_elec(nelem,maxnum_funcvalues_elec)
    real(dp) :: avvalue_elec(nelem,maxnum_funcvalues_elec)

    real(dp), dimension(:,:)  , allocatable :: sens
    real(dp), dimension(:,:)  , allocatable :: sense

    contains

!   2do in the whole module:
!   seed for the random number generator should be the trajectory number, not a sum of start number and total number of trajectories
!   variable declarations concerning RuNNer in the corresponding modules, but set to (our) default values has to be done before reading out keywords (own subroutine called in compute_nene)
!
!   check how many mpi routines have to stay in the code, at least set the few default values so that no error will occur due to wrong default mpi settings, therefore the mpi_dummy_routines.f90 file makes sense
!   declare all needed variables which are not declared in modules (especially look at main, initnn, predict)
!
!   check if every useful information concerning RuNNer setup is written (like printinputnn etc.)
!   add things concerning extrapolation warnings like in the RuNNer-LAMMPS interface
!   sort elements when reading in the structure from poscar, mxt, xyz files!!
!   ask Sascha about writing 2 (1) additional files per trajectory (wanted?)
!   check latest version of RuNNer files if all cases for symmetry functions (5,6 as debug functions etc.) are still included
!   check latest version of RuNNer files if any keyword changed, removed or added


    ! Here all necessary files and keywords are read in for the high-dimensional neural network potentials (HDNNPs)
    subroutine read_nene(atoms, inp_unit)

        use open_file, only : open_for_read
        !use run_config, only : simparams
        use useful_things, only : lower_case, split_string, file_exists

        type(universe), intent(inout) :: atoms
        integer, intent(in) :: inp_unit

        integer :: nwords, ios = 0
        character(len=max_string_length) :: buffer
        character(len=max_string_length) :: words(100)
        character(len=max_string_length) :: inp_path

        character(len=max_string_length) :: filename_inpnn, filename_scaling, filename_scalinge

        integer, parameter  :: inpnn_unit = 61

        integer  :: idx1, idx2
        integer  :: npairs_counter_1, npairs_counter_2, element_counter, nodes_counter
        integer  :: nuc_counter, ielem_counter
        integer  :: general_counter_1, general_counter_2, general_counter_3
        integer  :: k, j

        character(len=*), parameter :: err = "Error in read_nene: "
        character(len=*), parameter :: err_pes = "Error in the PES file: "

        character(len=*), parameter :: err_inpnn = "Error when reading input.nn: "
        character(len=*), parameter :: err_scaling = "Error when reading scaling.data: "
        character(len=*), parameter :: err_scalinge = "Error when reading scalinge.data: "

        character(len=*), parameter :: warn_inpnn = "Warning when reading input.nn: "

        ! initialize RuNNer related readout variable
        inp_path                    = default_string

        ! first read the pes file:
        ! line should read something like "H   H   proj    proj"
        read(inp_unit, '(A)', iostat=ios) buffer
        call split_string(buffer, words, nwords)

        if (nwords /= 4) stop err // "need four entries in interaction-defining lines"

        if (words(3) == "proj" .and. words(4) == "proj" .or. &
            words(3) == "proj" .and. words(4) == "latt" .or. &
            words(3) == "latt" .and. words(4) == "proj" .or. &
            words(3) == "latt" .and. words(4) == "latt") then

            idx1 = get_idx_from_name(atoms, words(1), is_proj=(words(3)=="proj"))
            idx2 = get_idx_from_name(atoms, words(2), is_proj=(words(4)=="proj"))

            if (atoms%pes(idx1,idx2) /= default_int) then
                print *, err // "pes already defined for atoms", words(1), words(3), words(2), words(4)
                stop
            end if

        else
            print *, err // "interaction must be defined via 'proj' and 'latt' keywords"
            stop
        end if

        ! set the pes type in the atoms object
        atoms%pes(idx1,idx2) = pes_id_nene
        atoms%pes(idx2,idx1) = pes_id_nene


        do
            read(inp_unit, '(A)', iostat=ios) buffer
            call split_string(buffer, words, nwords)

            ! pes block terminated, exit
            if (nwords == 0 .or. ios /= 0) then
                exit

            ! something went wrong
            else if (nwords /= 2) then
                print *,  err // err_pes // "PES parameters must consist of key value pairs. A parameter block must be terminated by a blank line."
                stop
            end if

            call lower_case(words(1))

            ! readout of folder with RuNNer related files
            select case (words(1))

                case ('inp_dir')

                    if (inp_path /= default_string) stop err // err_pes // 'Multiple use of the inp_dir key'
                    read(words(2), '(A)') inp_path

                case default

                    print *, err, err_pes, "unknown nene parameter ", words(1)
                    stop

            end select

        end do

        ! set name strings for RuNNer related files
        filename_inpnn      = trim(inp_path) // "input.nn"
        filename_scaling    = trim(inp_path) // "scaling.data"
        filename_scalinge   = trim(inp_path) // "scalinge.data"


        ! in case of the HDNNPs several additional input files have to be read

        ! read all input keywords from input.nn several times to respect dependencies

!       read in keywords related to input.nn according to the following files from RuNNer (chronologically)
!       1) getdimensions.f90
!       2) paircount.f90
!       3) readkeywords.f90
!       4) readinput.f90

        ! start readout according to main.f90
        call mpi_init(mpierror)
        call mpi_comm_size(mpi_comm_world,mpisize,mpierror)
        call mpi_comm_rank(mpi_comm_world,mpirank,mpierror)

        ! set all variables to default values -> rethink this subroutine!!
        call set_defaults()

        !call initnn(iseed)

        ! start readout of input.nn according to initnn.f90
        listdim    = 100000

        call get_nnconstants()
        !call writeheader()

        !call initialization(ielem,lelement) -> here only getdimensions, paircount and checkstructures are needed

        ! start readout according to initialization.f90

        ! start readout according to getdimensions.f90

        ! check existance of input.nn
        if (.not. file_exists(filename_inpnn)) stop err // err_inpnn // "file does not exist"

        call open_for_read(inpnn_unit, filename_inpnn); ios = 0

        do while (ios == 0)
            read(inpnn_unit, '(A)', iostat=ios) buffer
            if (ios == 0) then
                !line = line + 1
                call split_string(buffer, words, nwords)

                select case (words(1))

                    case ('nn_type_short')
                        if (nn_type_short /= default_int) stop err // err_inpnn // 'Multiple use of the nn_type_short key'
                        if (nwords == 2) then
                            read(words(2),'(i1000)', iostat=ios) nn_type_short
                            if (ios /= 0) stop err // err_inpnn // "nn_type_short value must be integer"

                            select case (words(2))

                                case ('1')
                                    ! Gandalf says: you shall pass

                                case ('2')
                                    print *, err, err_inpnn, "nn_type_short 2 not supported, Pair NN not implemented!"
                                    stop

                                case default
                                    print *, err, err_inpnn, "Error in nn_type_short key value, ", words(2), " not implemented"
                                    stop

                            end select

                        else
                            print *, err, err_inpnn, "nn_type_short key needs a single argument"; stop
                        end if

                    case ('runner_mode')
                        if (mode /= default_int) stop err // err_inpnn // 'Multiple use of the runner_mode key'
                        if (nwords == 2) then
                            read(words(2),'(i1000)', iostat=ios) mode
                            if (ios /= 0) stop err // err_inpnn // "runner_mode value must be integer"
                            if (mode /= 3) then
                                print *, err, err_inpnn, "Only mode 3 (prediction mode) available"; stop
                        else
                            print *, err, err_inpnn, "runner_mode key needs a single argument"; stop
                        end if

                    case ('use_short_nn')
                        if (lshort /= default_bool) stop err // err_inpnn // 'Multiple use of the use_short_nn key'
                        if (nwords == 1) then
                            lshort = .true.
                        else
                            print *, err, err_inpnn, "use_short_nn key needs no argument(s)"; stop
                        end if

                    case ('use_electrostatics')
                        if (lelec /= default_bool) stop err // err_inpnn // 'Multiple use of the use_electrostatics key'
                        if (nwords == 1) then
                            lelec = .true.
                        else
                            print *, err, err_inpnn, "use_electrostatics key needs no argument(s)"; stop
                        end if

                    case ('electrostatic_type', 'nn_type_elec')
                        if (nn_type_elec /= default_int) stop err // err_inpnn // 'Multiple use of the electrostatic_type/nn_type_elec key'
                        if (nwords == 2) then
                            read(words(2),'(i1000)', iostat=ios) nn_type_elec
                            if (ios /= 0) stop err // err_inpnn // "electrostatic_type/nn_type_elec value must be integer"
                        else
                            print *, err, err_inpnn, "electrostatic_type/nn_type_elec key needs a single argument"; stop
                        end if

                    case default
                        ! for every other keyword pass here, check for unrecognized keywords later

                end select

            !else
            !    print *, err, err_inpnn, 'iostat = ', ios
            !    stop
            end if

        end do

        close(inpnn_unit)


        call open_for_read(inpnn_unit, filename_inpnn); ios = 0

        do while (ios == 0)
            read(inpnn_unit, '(A)', iostat=ios) buffer
            if (ios == 0) then
                !line = line + 1
                call split_string(buffer, words, nwords)

                select case (words(1))

                    case ('debug_mode')
                        if (lfounddebug /= default_bool) stop err // err_inpnn // 'Multiple use of the debug_mode key'
                        if (nwords == 1) then
                            lfounddebug = .true.
                            ldebug = .true.
                        else
                            print *, err, err_inpnn, "debug_mode key needs no argument(s)"; stop
                        end if

                    case ('global_hidden_layers_short')
                        if (lfound_num_layersshort /= default_bool) stop err // err_inpnn // 'Multiple use of the global_hidden_layers_short key'
                        if (nwords == 2) then
                            lfound_num_layersshort = .true.
                            read(words(2),'(i1000)', iostat=ios) maxnum_layers_short_atomic
                            if (ios /= 0) stop err // err_inpnn // "global_hidden_layers_short value must be integer"
                            maxnum_layers_short_atomic = maxnum_layers_short_atomic + 1
                        else
                            print *, err, err_inpnn, "global_hidden_layers_short key needs a single argument"; stop
                        end if

                    case ('global_hidden_layers_electrostatic')
                        if (lfound_num_layersewald /= default_bool) stop err // err_inpnn // 'Multiple use of the global_hidden_layers_electrostatic key'
                        if (nwords == 2) then
                            lfound_num_layersewald = .true.
                            read(words(2),'(i1000)', iostat=ios) maxnum_layers_elec
                            if (ios /= 0) stop err // err_inpnn // "global_hidden_layers_electrostatic value must be integer"
                            maxnum_layers_elec = maxnum_layers_elec + 1
                        else
                            print *, err, err_inpnn, "global_hidden_layers_electrostatic key needs a single argument"; stop
                        end if

                    case ('global_hidden_layers_pair')
                        print *, err, err_inpnn, "global_hidden_layers_pair key not supported, Pair NN not implemented"; stop

                    case ('use_atom_energies')
                        if (lfound_luseatomenergies /= default_bool) stop err // err_inpnn // 'Multiple use of the use_atom_energies key'
                        if (nwords == 1) then
                            lfound_luseatomenergies = .true.
                            luseatomenergies = .true.
                        else
                            print *, err, err_inpnn, "use_atom_energies key needs no argument(s)"; stop
                        end if

                    case ('use_atom_charges')
                        if (lfound_luseatomcharges /= default_bool) stop err // err_inpnn // 'Multiple use of the use_atom_charges key'
                        if (nwords == 1) then
                            lfound_luseatomcharges = .true.
                            luseatomcharges = .true.
                        else
                            print *, err, err_inpnn, "use_atom_charges key needs no argument(s)"; stop
                        end if

                    case ('number_of_elements')
                        if (lfound_nelem /= default_bool) stop err // err_inpnn // 'Multiple use of the number_of_elements key'
                        if (nwords == 2) then
                            lfound_nelem = .true.
                            read(words(2),'(i1000)', iostat=ios) nelem
                            if (ios /= 0) stop err // err_inpnn // "number_of_elements value must be integer"
                            if (nelem /= atoms%ntypes) stop err // err_inpnn // "number of elements in input.nn and in structure file differ"
                            npairs = 0
                            do npairs_counter_1 = 1,nelem
                                do npairs_counter_2 = npairs_counter_1,nelem
                                    npairs = npairs + 1
                                end do
                            end do
                        else
                            print *, err, err_inpnn, "number_of_elements key needs a single argument"; stop
                        end if

                    case default
                        ! for every other keyword pass here, check for unrecognized keywords later

                end select

            !else
            !    print *, err, err_inpnn, 'iostat = ', ios
            !    stop
            end if

        end do

        close(inpnn_unit)

        if (lshort .and. (nn_type_short == 1) .and. (maxnum_layers_short_atomic == default_int)) stop err // err_inpnn // 'global_hidden_layers_short key not set'
        !if (lshort .and. (nn_type_short == 2) .and. (maxnum_layers_short_pair == default_int)) stop err // err_inpnn // 'global_hidden_layers_pairs key not set'
        if (lelec .and. (nn_type_elec == 1) .and. (maxnum_layers_elec == default_int)) stop err // err_inpnn // 'global_hidden_layers_electrostatic key not set'

        allocate(nucelem(nelem))
        allocate(element(nelem))
        allocate(dmin_element(nelem*(nelem+1)/2))


        call open_for_read(inpnn_unit, filename_inpnn); ios = 0 ! maybe move to readout before since nelem is given by atoms%ntypes

        do while (ios == 0)
            read(inpnn_unit, '(A)', iostat=ios) buffer
            if (ios == 0) then
                !line = line + 1
                call split_string(buffer, words, nwords)

                select case (words(1))

                    case ('elements')
                        if (any(element /= default_string)) stop err // err_inpnn // 'Multiple use of the elements key'
                        !if (nwords == atoms%nnelem+1) then
                        if (nwords == atoms%ntypes+1) then ! check if ntypes is equal to number of elements!!
                        !if (nwords == nelem+1) then
                            !do element_counter = 1,atoms%nelem
                            do element_counter = 1,atoms%ntypes
                            !do element_counter = 1,nelem
                                read(words(element_counter+1),'(A)') element(element_counter) !! check for valid name will be done later!
                            end do
                            if (any(element /= atoms%name)) stop err // err_inpnn // "element names in input.nn and in input structure file differ"
                        else
                            print *, err, err_inpnn, "elements key does not match with number of element types"; stop
                        end if

                    case default
                        ! for every other keyword pass here, check for unrecognized keywords later

                end select

            !else
            !    print *, err, err_inpnn, 'iostat = ', ios
            !    stop
            end if

        end do

        close(inpnn_unit)

        do nuc_counter=1,atoms%ntypes
            call nuccharge(element(nuc_counter),nucelem(nuc_counter))
        end do

        call sortelements()

        if (.not. lfound_num_layersshort) then
            maxnum_layers_short_atomic = 0
        end if
        if (.not. lfound_num_layersewald) then
            maxnum_layers_elec = 0
        end if

        if (lfound_nelem == default_bool) stop err // err_inpnn // "number_of_elements key not found"

        allocate(num_funcvalues_local(102))
        allocate(num_funcvaluese_local(102))
        num_funcvalues_local(:) = 0
        num_funcvaluese_local(:) = 0

        if (maxnum_layers_short_atomic .gt. 0) then
            allocate(nodes_short_local(0:maxnum_layers_short_atomic))
            nodes_short_local(:) = default_int ! = 0 in getdimensions.f90
        end if
        if (maxnum_layers_selec .gt. 0) then
            allocate(nodes_ewald_local(0:maxnum_layers_elec))
            nodes_ewald_local(:) = default_int ! = 0 in getdimensions.f90
        end if


        call open_for_read(inpnn_unit, filename_inpnn); ios = 0

        do while (ios == 0)
            read(inpnn_unit, '(A)', iostat=ios) buffer
            if (ios == 0) then
                !line = line + 1
                call split_string(buffer, words, nwords)

                select case (words(1))

                    case ('global_nodes_short')
                        if (nodes_short_local /= default_int) stop err // err_inpnn // 'Multiple use of the global_nodes_short key'
                        if (nwords == maxnum_layers_short_atomic+1) then
                            do nodes_counter = 1,maxnum_layers_short_atomic-1
                                read(words(nodes_counter+1),'(i1000)', iostat=ios) nodes_short_local(nodes_counter)
                                if (ios /= 0) stop err // err_inpnn // "global_nodes_short value"// nodes_counter// " must be integer"
                            end do
                        else
                            print *, err, err_inpnn, "global_nodes_short argument number does not match with global_hidden_layers_short value"; stop
                        end if

                    case ('global_nodes_electrostatic')
                        if (nodes_ewald_local /= default_int) stop err // err_inpnn // 'Multiple use of the global_nodes_electrostatic key'
                        if (nwords == maxnum_layers_elec+1) then
                            do nodes_counter = 1,maxnum_layers_elec-1
                                read(words(nodes_counter+1),'(i1000)', iostat=ios) nodes_ewald_local(nodes_counter)
                                if (ios /= 0) stop err // err_inpnn // "global_nodes_electrostatic value" // nodes_counter // " must be integer"
                            end do
                        else
                            print *, err, err_inpnn, "global_nodes_electrostatic argument number ", nwords, " does not match with global_hidden_layers_electrostatic value ", maxnum_layers_elec-1; stop
                        end if

                    case ('global_nodes_pair')
                        print *, err, err_inpnn, "global_nodes_pair key not supported, Pair NN not implemented"; stop

                    case ('element_symfunction_short')
                        read(words(2),'(A)', iostat=ios) elementtemp
                        read(words(3),'(i1000)', iostat=ios) function_type_local
                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_short second argument value must be integer"
                        call nuccharge(elementtemp, ztemp)

                        select case (words(3))

                            case ('1','2','4')
                                num_funcvalues_local(ztemp) = num_funcvalues_local(ztemp) + nelem

                            case ('3','8','9')
                                num_funcvalues_local(ztemp) = num_funcvalues_local(ztemp) + nelem
                                if (nelem .gt. 1) then
                                    do general_counter_1 = 1,nelem-1
                                        num_funcvalues_local(ztemp) = num_funcvalues_local(ztemp) + general_counter_1
                                    end do
                                end if

                            case ('5','6') ! debug functions
                                num_funcvalues_local(ztemp) = num_funcvalues_local(ztemp) + 1

                            case default
                                print *, err, err_inpnn, "Error in element_symfunction_short key, symfunction type ", words(3), " not implemented"
                                stop

                        end select

                    case ('element_symfunction_electrostatic')
                        read(words(2),'(A)', iostat=ios) elementtemp
                        read(words(3),'(i1000)', iostat=ios) function_type_local
                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic second argument value must be integer"
                        call nuccharge(elementtemp, ztemp)

                        select case (words(3))

                            case ('1','2','4')
                                num_funcvaluese_local(ztemp) = num_funcvaluese_local(ztemp) + nelem

                            case ('3','8','9')
                                num_funcvaluese_local(ztemp) = num_funcvaluese_local(ztemp) + nelem
                                if (nelem .gt. 1) then
                                    do general_counter_1 = 1,nelem-1
                                        num_funcvaluese_local(ztemp) = num_funcvaluese_local(ztemp) + general_counter_1
                                    end do
                                end if

                            case ('5','6') ! debug functions
                                num_funcvalues_local(ztemp) = num_funcvalues_local(ztemp) + 1

                            case default
                                print *, err, err_inpnn, "Error in element_symfunction_electrostatic key, symfunction type ", words(3), " not implemented"
                                stop

                        end select

                    case ('global_symfunction_short')
                        read(words(2),'(i1000)', iostat=ios) function_type_local
                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_short second argument value must be integer"
                        !call nuccharge(elementtemp, ztemp)

                        select case (words(2))

                            case ('1','2','4')
                                do general_counter_1 = 1,nelem
                                    num_funcvalues_local(nucelem(general_counter_1)) = num_funcvalues_local(nucelem(general_counter_1)) + nelem
                                end do

                            case ('3','8','9')
                                do general_counter_1 = 1,nelem
                                    num_funcvalues_local(nucelem(general_counter_1)) = num_funcvalues_local(nucelem(general_counter_1)) + nelem
                                end do
                                do general_counter_1 = 1,nelem
                                    if (nelem .gt. 1) then
                                        do general_counter_2 = 1,nelem-1
                                            num_funcvalues_local(nucelem(general_counter_1)) = num_funcvalues_local(nucelem(general_counter_1)) + general_counter_2
                                        end do
                                    end if
                                end do

                            case ('5','6') ! debug functions
                                do general_counter_1 = 1,nelem
                                    num_funcvalues_local(nucelem(general_counter_1)) = num_funcvalues_local(nucelem(general_counter_1)) + 1
                                end do

                            case default
                                print *, err, err_inpnn, "Error in global_symfunction_short key, symfunction type ", words(2), " not implemented"
                                stop

                        end select

                    case ('global_symfunction_electrostatic')
                        read(words(2),'(i1000)', iostat=ios) function_type_local
                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic second argument value must be integer"
                        !call nuccharge(elementtemp, ztemp)

                        select case (words(2))

                            case ('1','2','4')
                                do general_counter_1 = 1,nelem
                                    num_funcvaluese_local(nucelem(general_counter_1)) = num_funcvaluese_local(nucelem(general_counter_1)) + nelem
                                end do

                            case ('3','8','9')
                                do general_counter_1 = 1,nelem
                                    num_funcvaluese_local(nucelem(general_counter_1)) = num_funcvaluese_local(nucelem(general_counter_1)) + nelem
                                end do
                                do general_counter_1 = 1,nelem
                                    if (nelem .gt. 1) then
                                        do general_counter_2 = 1,nelem-1
                                            num_funcvaluese_local(nucelem(general_counter_1)) = num_funcvaluese_local(nucelem(general_counter_1)) + general_counter_2
                                        end do
                                    end if
                                end do

                            case ('5','6') ! only for Pair NN
                                do general_counter_1 = 1,nelem
                                    num_funcvaluese_local(nucelem(general_counter_1)) = num_funcvaluese_local(nucelem(general_counter_1)) + 1
                                end do

                            case default
                                print *, err, err_inpnn, "Error in global_symfunction_electrostatic key, symfunction type ", words(2), " not implemented"
                                stop

                        end select

                    case ('symfunction_short')
                        read(words(2),'(A)', iostat=ios) elementtemp
                        call nuccharge(elementtemp, ztemp)
                        num_funcvalues_local(ztemp) = num_funcvalues_local(ztemp) + 1

                    case ('symfunction_electrostatic')
                        read(words(2),'(A)', iostat=ios) elementtemp
                        call nuccharge(elementtemp, ztemp)
                        num_funcvaluese_local(ztemp) = num_funcvaluese_local(ztemp) + 1

                    case ('pairsymfunction_short')
                        print *, err, err_inpnn, "pairsymfunction_short key is not supported, Pair NN not implemented"

                    case ('element_pairsymfunction_short')
                        print *, err, err_inpnn, "element_pairsymfunction_short key is not supported, Pair NN not implemented"

                    case ('global_pairsymfunction_short')
                        print *, err, err_inpnn, "global_pairsymfunction_short key is not supported, Pair NN not implemented"

                    case ('global_symfunction_short_pair')
                        print *, err, err_inpnn, "global_symfunction_short_pair key is not supported, Pair NN not implemented"

                    case default
                        ! for every other keyword pass here, check for unrecognized keywords later

                end select

            !else
            !    print *, err, err_inpnn, 'iostat = ', ios
            !    stop
            end if

        end do

        close(inpnn_unit)

        if (maxnum_layers_short_atomic .gt. 0) then
            do general_counter_1 = 1,maxnum_layers_short_atomic
                maxnodes_short_atomic = max(maxnodes_short_atomic, nodes_short_local(general_counter_1))
            end do
        end if

        if (maxnum_layers_elec .gt. 0) then
            do general_counter_1 = 1,maxnum_layers_elec
                maxnodes_elec = max(maxnodes_elec, nodes_ewald_local(general_counter_1))
            end do
        end if

        if (allocated(nodes_ewald_local)) deallocate(nodes_ewald_local)
        if (allocated(nodes_short_local)) deallocate(nodes_short_local)

        do general_counter_1 = 1,102
            maxnum_funcvalues_short_atomic = max(maxnum_funcvalues_short_atomic, num_funcvalues_local(general_counter_1))
            maxnum_funcvalues_elec = max(maxnum_funcvalues_elec, num_funcvaluese_local(general_counter_1))
        end do

        deallocate(num_funcvalues_local)
        deallocate(num_funcvaluese_local)

        deallocate(nucelem)
        deallocate(element)
        !end readout according to getdimensions.f90

        !start readout according to paircount.f90
        if (nn_type_short == 1) then

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    !line = line + 1
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('global_symfunction_short')
                            read(words(2),'(i1000)', iostat=ios) function_type_temp
                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short first argument value must be integer"
                            !call lower_case(words(2))
                            select case (words(2))

                                case ('1')
                                    if (nwords == 3) then
                                        read(words(3),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type "// words(2)// " argument "// nwords-1// " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 2 arguments"; stop
                                    end if

                                case ('2')
                                    if (nwords == 5) then
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type " // words(2) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 4 arguments"; stop
                                    end if

                                case ('3')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type " // words(2) // "argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 5 arguments"; stop
                                    end if

                                case ('4')
                                    if (nwords == 4) then
                                        read(words(4),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type " // words(2) // "argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 3 arguments"; stop
                                    end if

                                case ('5','6')
                                    ! just let the debug functions pass

                                case ('8')
                                    if (nwords == 5) then
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type " // words(2) // "argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 4 arguments"; stop
                                    end if

                                case ('9')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type " // words(2) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 5 arguments"; stop
                                    end if

                                case default
                                    print *, err, err_inpnn, "Error in global_symfunction_short key, symfunction type ", words(2), " not implemented"
                                    stop

                            end select

                        case ('element_symfunction_short')
                            read(words(2),'(A)') elementtemp1
                            read(words(3),'(i1000)', iostat=ios) function_type_temp
                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short second argument value must be integer"
                            !call lower_case(words(2))

                            select case (words(3))

                                case ('1')
                                    if (nwords == 4) then
                                        read(words(4),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 3 arguments"; stop
                                    end if

                                case ('2')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 5 arguments"; stop
                                    end if

                                case ('3')
                                    if (nwords == 7) then
                                        read(words(7),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 6 arguments"; stop
                                    end if

                                case ('4')
                                    if (nwords == 5) then
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 4 arguments"; stop
                                    end if

                                case ('5','6')
                                    ! just let the debug functions pass

                                case ('8')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 5 arguments"; stop
                                    end if

                                case ('9')
                                    if (nwords == 7) then
                                        read(words(7),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 6 arguments"; stop
                                    end if

                                case default
                                    print *, err, err_inpnn, "Error in element_symfunction_short key, symfunction type ", words(3), " not implemented"
                                    stop

                            end select

                        case ('symfunction_short')
                            read((words(2),'(A)') elementtemp1
                            read(words(3),'(i1000)', iostat=ios) function_type_temp
                            if (ios /= 0) stop err // err_inpnn // "symfunction_short second argument value must be integer"
                            !call lower_case(words(2))

                            select case (words(3))

                                case ('1')
                                    if (nwords == 5) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 4 arguments"; stop
                                    end if

                                case ('2')
                                    if (nwords == 7) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(7),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 6 arguments"; stop
                                    end if

                                case ('3')
                                    if (nwords == 9) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),'(A)') elementtemp3
                                        read(words(9),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 8 arguments"; stop
                                    end if

                                case ('4')
                                    if (nwords == 6) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 5 arguments"; stop
                                    end if

                                case ('5','6')
                                    ! just let the debug functions pass

                                case ('8')
                                    if (nwords == 8) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),'(A)') elementtemp3
                                        read(words(8),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 7 arguments"; stop
                                    end if

                                case ('9')
                                    if (nwords == 9) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),'(A)') elementtemp3
                                        read(words(9),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_short type " // words(3) // " argument " // nwords-1 // " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 8 arguments"; stop
                                    end if

                                case default
                                    print *, err, err_inpnn, "Error in symfunction_short key, symfunction type ", words(3), " not implemented"
                                    stop

                            end select

                        case default
                            ! for every other keyword pass here, check for unrecognized keywords later
                            !if (trim(words(1)) /= '' .and. words(1)(1:1) /= '#') & ! check for empty and comment lines
                                !print *, warn_inpnn, 'Skipping invalid label ', trim(words(1)),' in line ', line

                    end select

                    maxcutoff_local = max(maxcutoff_local, funccutoff_local)

                !else
                !    print *, err, err_inpnn, 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

        end if

        if (nn_type_elec == 1) .or. (nn_type_elec == 3) .or. (nn_type_elec == 4) then

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    !line = line + 1
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('global_symfunction_electrostatic')
                            read(words(2),'(i1000)', iostat=ios) function_type_temp
                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic first argument value must be integer"

                            select case (words(2))

                                case ('1')
                                    if (nwords == 3) then
                                        read(words(3),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 2 arguments"; stop
                                    end if

                                case ('2')
                                    if (nwords == 5) then
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 4 arguments"; stop
                                    end if

                                case ('3')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 5 arguments"; stop
                                    end if

                                case ('4')
                                    if (nwords == 4) then
                                        read(words(4),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 3 arguments"; stop
                                    end if

                                case ('8')
                                    if (nwords == 5) then
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 4 arguments"; stop
                                    end if

                                case ('9')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 6 arguments"; stop
                                    end if

                                case default
                                    print *, err, err_inpnn, "Error in global_symfunction_electrostatic key, symfunction type ", words(2), " not implemented"
                                    stop

                            end select

                        case ('element_symfunction_electrostatic')
                            read(words(2),'(A)') elementtemp1
                            read(words(3),'(i1000)', iostat=ios) function_type_temp
                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic second argument value must be integer"
                            !call lower_case(words(2))

                            select case (words(3))

                                case ('1')
                                    if (nwords == 4) then
                                        read(words(4),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 3 arguments"; stop
                                    end if

                                case ('2')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 5 arguments"; stop
                                    end if

                                case ('3')
                                    if (nwords == 7) then
                                        read(words(7),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 6 arguments"; stop
                                    end if

                                case ('4')
                                    if (nwords == 5) then
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 4 arguments"; stop
                                    end if

                                case ('8')
                                    if (nwords == 6) then
                                        read(words(6),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 5 arguments"; stop
                                    end if

                                case ('9')
                                    if (nwords == 7) then
                                        read(words(7),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 6 arguments"; stop
                                    end if

                                case default
                                    print *, err, err_inpnn, "Error in element_symfunction_electrostatic key, symfunction type ", words(3), " not implemented"
                                    stop

                            end select

                        case ('symfunction_electrostatic')
                            read((words(2),'(A)') elementtemp1
                            read(words(3),'(i1000)', iostat=ios) function_type_temp
                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic second argument value must be integer"
                            !call lower_case(words(2))

                            select case (words(3))

                                case ('1')
                                    if (nwords == 5) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 4 arguments"; stop
                                    end if

                                case ('2')
                                    if (nwords == 7) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(7),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 6 arguments"; stop
                                    end if

                                case ('3')
                                    if (nwords == 9) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),'(A)') elementtemp3
                                        read(words(9),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 8 arguments"; stop
                                    end if

                                case ('4')
                                    if (nwords == 7) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(7),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 6 arguments"; stop
                                    end if

                                case ('8')
                                    if (nwords == 8) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),'(A)') elementtemp3
                                        read(words(8),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 7 arguments"; stop
                                    end if

                                case ('9')
                                    if (nwords == 9) then
                                        read(words(4),'(A)') elementtemp2
                                        read(words(5),'(A)') elementtemp3
                                        read(words(9),*, iostat=ios) funccutoff_local
                                        if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument ", nwords-1, " must be a number"
                                    else
                                        print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 8 arguments"; stop
                                    end if

                                case default
                                    print *, err, err_inpnn, "Error in symfunction_electrostatic key, symfunction type ", words(3), " not implemented"; stop

                            end select

                        case default
                            ! for every other keyword pass here, check for unrecognized keywords later
                            !if (trim(words(1)) /= '' .and. words(1)(1:1) /= '#') & ! check for empty and comment lines
                                !print *, warn_inpnn, 'Skipping invalid label ', trim(words(1)),' in line ', line

                    end select

                    maxcutoff_local = max(maxcutoff_local, funccutoff_local)

                !else
                !    print *, err, err_inpnn, 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

        end if

        if (maxcutoff_local == 0.0d0) then
            print *, err, err_inpnn, "maxcutoff_local is not set, specify symmetry functions"
            stop
        end if

        max_num_pairs = 0
        ! end readout according to paircount.f90

        ! start readout according to checkstructures.f90

        !call checkonestructure(i1,lelement)

        ! start readout according to checkonestructure.f90

        !if(keyword.eq.'lattice') then
        !    nlattice=nlattice+1
        !    backspace(dataunit)
        !    read(dataunit,*,err=90)keyword,(lattice(nlattice,i),i=1,3)
        !endif

        do k = 1,3
            lattice(k,:) = atoms%simbox(:,k) * ang2bohr
        end do

        !if(keyword.eq.'atom') then
        !    num_atoms=num_atoms+1
        !    backspace(dataunit)
        !    read(dataunit,*,err=91)keyword,(xyzstruct(i,num_atoms),i=1,3),&
        !        elementsymbol(num_atoms),atomcharge(num_atoms),&
        !        atomenergy(num_atoms),(totalforce(i,num_atoms),i=1,3)
        !    call nuccharge(elementsymbol(num_atoms),zelem(num_atoms))
        !    lelement(zelem(num_atoms))=.true. ! element found
        !endif

        do j = 1,atoms%natoms ! this is done here to check if it is a valid structure
            xyzstruct(:,j) = atoms%r(:,:,j) * ang2bohr
            elementsymbol(j) = atoms%name(atoms%idx(j))
            call nuccharge(elementsymbol(j),zelem(j))
            lelement(zelem(j)) = .true.
        end do

        ! a periodic structure is assumed
        call translate(atoms%natoms,lattice,xyzstruct)

        !! check if lattice vectors make sense
        if(lperiodic)then
            call getvolume(lattice,volume)
            if(volume.lt.0.0000001d0)then
                write(*,*)'ERROR: volume of a periodic structure is very small ',volume
                stop
            endif
        endif
        ! end readout according to checkonestructure.f90

        ielem=0
        do ielem_counter=1,102
            if(lelement(ielem_counter)) ielem=ielem+1
        enddo
        ! end readout according to checkstructures.f90

        ! further readout according to initnn.f90

        !call distribute_nnflags() ! only mpi dummy routines

        if(lshort.and.(nn_type_short.eq.1))then
        allocate (num_funcvalues_short_atomic(nelem))
        num_funcvalues_short_atomic(:)=0
        allocate (windex_short_atomic(2*maxnum_layers_short_atomic,nelem))
        allocate (num_layers_short_atomic(nelem))
        num_layers_short_atomic(:)=maxnum_layers_short_atomic
        allocate (actfunc_short_atomic(maxnodes_short_atomic,maxnum_layers_short_atomic,nelem))
        allocate (nodes_short_atomic(0:maxnum_layers_short_atomic,nelem))
        nodes_short_atomic(:,:)=0
        allocate (num_weights_short_atomic(nelem))
        num_weights_short_atomic(:)=0
        end if

        if(lelec.and.(nn_type_elec.eq.1))then
        allocate (num_funcvalues_elec(nelem))
        num_funcvalues_elec(:)=0
        allocate (windex_elec(2*maxnum_layers_elec,nelem))
        allocate (num_layers_elec(nelem))
        num_layers_elec(:)=maxnum_layers_elec
        allocate (actfunc_elec(maxnodes_elec,maxnum_layers_elec,nelem))
        allocate (nodes_elec(0:maxnum_layers_elec,nelem))
        nodes_elec(:,:)=0
        allocate (num_weights_elec(nelem))
        num_weights_elec(:)=0
        endif

        allocate (fixedcharge(nelem))
        fixedcharge(:)=0.0d0
        allocate (nucelem(nelem))
        allocate (element(nelem))
        allocate (atomrefenergies(nelem))
        allocate (elempair(npairs,2))
        elempair(:,:)=0

        call allocatesymfunctions()

        !call readinput(ielem,iseed,lelement) !ielem iseed defined in main.f90/initnn.f90 -> I defined it in get_defaults.f90

        ! start readout of input.nn according to readinput.f90


            !call initializecounters() ! we use default values, but compare with

            if(lshort.and.(nn_type_short.eq.1))then
                nodes_short_atomic_temp(:)   =0
                actfunc_short_atomic_dummy(:)=' '
            endif
            endif
            if(lelec.and.(nn_type_elec.eq.1))then
                nodes_elec_temp(:)           =0
                actfunc_elec_dummy(:)        =' '
            endif
            kalmanlambda_local =0.98000d0
            kalmanlambdae_local=0.98000d0
            iseed=200

            if(lshort.and.(nn_type_short.eq.1))then
                windex_short_atomic(:,:)    =0
                num_weights_short_atomic(:) =0
                maxnum_weights_short_atomic =0
            endif
            if(lelec.and.(nn_type_elec.eq.1))then
                windex_elec(:,:)            =0
                num_weights_elec(:)         =0
                maxnum_weights_elec         =0
            endif

            !call readkeywords(iseed, nodes_short_atomic_temp,nodes_elec_temp,nodes_short_pair_temp, kalmanlambda_local,kalmanlambdae_local)


            ! start readout according to readkeywords.f90
            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    line = line + 1
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        ! add already read keywords here so that a keyword which is NOT related to RuNNer will be recognized!!
                        case ('nn_type_short') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('runner_mode') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('use_short_nn') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('use_electrostatics') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('electrostatic_type', 'nn_type_elec') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('debug_mode') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('global_hidden_layers_short') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('global_hidden_layers_electrostatic') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        !case ('global_hidden_layers_pair') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        !case ('use_atom_energies') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        !case ('use_atom_charges') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('number_of_elements') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('elements') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        !case ('global_nodes_short')
                            ! do nothing here, just let it pass

                        !case ('global_nodes_electrostatic')
                            ! do nothing here, just let it pass

                        !case ('global_nodes_pair')
                            ! do nothing here, just let it pass

                        case ('element_symfunction_short') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('element_symfunction_electrostatic') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('global_symfunction_short', 'global_symfunction_short_atomic') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('global_symfunction_electrostatic', 'global_symfunction_elec') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('symfunction_short') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        case ('symfunction_electrostatic') !in readkeywords.f90
                            ! do nothing here, just let it pass

                        !case ('pairsymfunction_short') !in readkeywords.f90
                            ! done before, not needed here anymore

                        !case ('element_pairsymfunction_short') !in readkeywords.f90
                            ! done before, not needed here anymore

                        !case ('global_pairsymfunction_short') !in readkeywords.f90
                            ! done before, not needed here anymore


                        case ('check_input_forces')
                            if (inputforcethreshold /= default_real) stop err // err_inpnn // 'Multiple use of the check_input_forces key'
                            if (nwords == 2) then
                                lcheckinputforces = .true.
                                read(words(2),*, iostat=ios) inputforcethreshold
                                if (ios /= 0) stop err // err_inpnn // "check_input_forces value must be a number"
                            else
                                print *, err, err_inpnn, "check_input_forces key needs a single argument"; stop
                            end if

                        case ('print_force_components')
                            if (lprintforcecomponents /= default_bool) stop err // err_inpnn // 'Multiple use of the print_force_components key'
                            if (nwords == 1) then
                                lprintforcecomponents = .true.
                            else
                                print *, err, err_inpnn, "print_force_components key needs no argument(s)"; stop
                            end if

                        case ('ion_forces_only')
                            if (lionforcesonly /= default_int) stop err // err_inpnn // 'Multiple use of the ion_forces_only key'
                            if (nwords == 1) then
                                lionforcesonly = .true.
                            else
                                print *, err, err_inpnn, "ion_forces_only key needs no argument(s)"; stop
                            end if

                        case ('use_electrostatic_nn')
                            print *, err, err_inpnn, "use_electrostatic_nn key is obsolete, please use electrostatic_type and use_electrostatics instead"; stop

!                       case ('debug_mode')
!                           if (ldebug /= default_bool) stop err // err_inpnn // 'Multiple use of the debug_mode key'
!                           if (nwords == 1) then
!                               ldebug = .true.
!                           else
!                               print *, err, err_inpnn, "debug_mode key needs no argument(s)"; stop
!                           end if

                        case ('cutoff_type')
                            if (cutoff_type /= default_int) stop err // err_inpnn // 'Multiple use of the cutoff_type key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) cutoff_type
                                if (ios /= 0) stop err // err_inpnn // "cutoff_type value must be integer"
                            else
                                print *, err, err_inpnn, "cutoff_type key needs a single argument"; stop
                            end if

                        case ('cutoff_alpha')
                            if (cutoff_alpha /= default_real) stop err // err_inpnn // 'Multiple use of the cutoff_alpha key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) cutoff_alpha
                                if (ios /= 0) stop err // err_inpnn // "cutoff_alpha value must be a number"
                            else
                                print *, err, err_inpnn, "cutoff_alpha key needs a single argument"; stop
                            end if

                        case ('dynamic_force_grouping')
                            if (ldynforcegroup /= default_bool) stop err // err_inpnn // 'Multiple use of the dynamic_force_grouping key'
                            if (nwords == 3) then
                                ldynforcegroup = .true.
                                read(words(2),'(i1000)', iostat=ios) dynforcegroup_start
                                if (ios /= 0) stop err // err_inpnn // "dynamic_force_grouping first argument value must be integer"
                                read(words(3),'(i1000)', iostat=ios) dynforcegroup_step
                                if (ios /= 0) stop err // err_inpnn // "dynamic_force_grouping second argument value must be integer"
                            else
                                print *, err, err_inpnn, "dynamic_force_grouping key needs a single argument"; stop
                            end if

                        case ('detect_saturation')
                            if (ldetect_saturation /= default_bool) stop err // err_inpnn // 'Multiple use of the detect_saturation key'
                            if (nwords == 2) then
                                ldetect_saturation = .true.
                                read(words(2),*, iostat=ios) saturation_threshold
                                if (ios /= 0) stop err // err_inpnn // "detect_saturation value must be a number"
                            else
                                print *, err, err_inpnn, "detect_saturation key needs a single argument"; stop
                            end if

                        case ('data_clustering')
                            if (ldataclustering /= default_bool) stop err // err_inpnn // 'Multiple use of the data_clustering key'
                            if (nwords == 3) then
                                ldataclustering=.true.
                                read(words(2),*, iostat=ios) dataclusteringthreshold1
                                if (ios /= 0) stop err // err_inpnn // "data_clustering value must be a number"
                                read(words(3),*, iostat=ios) dataclusteringthreshold2
                                if (ios /= 0) stop err // err_inpnn // "data_clustering value must be a number"
                            else
                                print *, err, err_inpnn, "data_clustering key needs two arguments"; stop
                            end if

                        case ('analyze_error_energy_step')
                            if (analyze_error_energy_step /= default_real) stop err // err_inpnn // 'Multiple use of the analyze_error_energy_step key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) analyze_error_energy_step
                                if (ios /= 0) stop err // err_inpnn // "analyze_error_energy_step value must be a number"
                            else
                                print *, err, err_inpnn, "analyze_error_energy_step key needs a single argument"; stop
                            end if

                        case ('analyze_error_force_step')
                            if (analyze_error_force_step /= default_real) stop err // err_inpnn // 'Multiple use of the analyze_error_force_step key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) analyze_error_force_step
                                if (ios /= 0) stop err // err_inpnn // "analyze_error_force_step value must be a number"
                            else
                                print *, err, err_inpnn, "analyze_error_force_step key needs a single argument"; stop
                            end if

                        case ('analyze_error_charge_step')
                            if (analyze_error_charge_step /= default_real) stop err // err_inpnn // 'Multiple use of the analyze_error_charge_step key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) analyze_error_charge_step
                                if (ios /= 0) stop err // err_inpnn // "analyze_error_charge_step value must be a number"
                            else
                                print *, err, err_inpnn, "analyze_error_charge_step key needs a single argument"; stop
                            end if

                        case ('parallel_mode')
                            if (paramode /= default_int) stop err // err_inpnn // 'Multiple use of the parallel_mode key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) paramode
                                if (ios /= 0) stop err // err_inpnn // "parallel_mode value must be integer"
                                if (paramode /= 1) stop err // err_inpnn // "parallel_mode ", paramode, " not implemented, only parallel_mode 1 (serial version) available"
                            else
                                print *, err, err_inpnn, "parallel_mode key needs a single argument"; stop
                            end if

                        case ('symfunction_correlation')
                            if (lpearson_correlation /= default_bool) stop err // err_inpnn // 'Multiple use of the symfunction_correlation key'
                            if (nwords == 1) then
                                lpearson_correlation = .true.
                            else
                                print *, err, err_inpnn, "symfunction_correlation key needs no argument(s)"; stop
                            end if

                        case ('weight_analysis')
                            if (lweightanalysis /= default_bool) stop err // err_inpnn // 'Multiple use of the weight_analysis key'
                            if (nwords == 1) then
                                lweightanalysis = .true.
                            else
                                print *, err, err_inpnn, "weight_analysis key needs no argument(s)"; stop
                            end if

                        case ('environment_analysis')
                            if (lenvironmentanalysis /= default_bool) stop err // err_inpnn // 'Multiple use of the environment_analysis key'
                            if (nwords == 1) then
                                lenvironmentanalysis = .true.
                            else
                                print *, err, err_inpnn, "environment_analysis key needs no argument(s)"; stop
                            end if

                        case ('find_contradictions')
                            if (lfindcontradictions /= default_bool) stop err // err_inpnn // 'Multiple use of the find_contradictions key'
                            if (nwords == 3) then
                                lfindcontradictions = .true.
                                read(words(2),*, iostat=ios) deltagthres
                                if (ios /= 0) stop err // err_inpnn // "find_contradictions first argument value must be a number"
                                read(words(3),*, iostat=ios) deltafthres
                                if (ios /= 0) stop err // err_inpnn // "find_contradictions second argument value must be a number"
                            else
                                print *, err, err_inpnn, "find_contradictions key needs two arguments"; stop
                            end if

                        case ('use_old_scaling')
                            if (luseoldscaling /= default_bool) stop err // err_inpnn // 'Multiple use of the use_old_scaling key'
                            if (nwords == 1) then
                                luseoldscaling = .true.
                            else
                                print *, err, err_inpnn, "use_old_scaling key needs no argument(s)"; stop
                            end if

                        case ('md_mode')
                            if (lmd /= default_bool) stop err // err_inpnn // 'Multiple use of the md_mode key'
                            if (nwords == 1) then
                                lmd = .true.
                            else
                                print *, err, err_inpnn, "md_mode key needs no argument(s)"; stop
                            end if

                        !case ('global_nodes_short', 'global_nodes_short_atomic')
                        !case ('global_nodes_short_atomic')
                            !print *, err, err_inpnn, "global_nodes_short_atomic key is obsolete, please use global_nodes_short instead"; stop

                        case ('global_nodes_short')
                            if(lshort .and. (rainpparam%nn_type_short == 1)) then
                                if (nwords == maxnum_layers_short_atomic) then
                                    do general_counter_1 = 1,maxnum_layers_short_atomic-1
                                        read(words(general_counter_1+1),'(i1000)', iostat=ios) nodes_short_atomic_temp(general_counter_1)
                                        if (ios /= 0) stop err // err_inpnn // "global_nodes_short argument ", general_counter_1, " value must be integer"
                                    end do
                                    do general_counter_1 = 1,nelem
                                        do general_counter_2 = 1,maxnum_layers_short_atomic
                                            nodes_short_atomic(general_counter_2,general_counter_1) = nodes_short_atomic_temp(general_counter_2)
                                        end do
                                    end do
                                else
                                    print *, err, err_inpnn, "global_nodes_short key needs ", maxnum_layers_short_atomic-1, " arguments"; stop
                                end if
                            end if

                        case ('global_nodes_electrostatic')
                            if(lelec .and. (rainpparam%nn_type_elec == 1)) then
                                if (nwords == maxnum_layers_elec) then
                                    do general_counter_1 = 1,maxnum_layers_elec-1
                                        read(words(general_counter_1+1),'(i1000)', iostat=ios) nodes_elec_temp(general_counter_1)
                                        if (ios /= 0) stop err // err_inpnn // "global_nodes_electrostatic argument ", general_counter_1, " value must be integer"
                                    end do
                                    do general_counter_1 = 1,nelem
                                        do general_counter_2 = 1,maxnum_layers_elec
                                            nodes_elec(general_counter_2,general_counter_1) = nodes_elec_temp(general_counter_2)
                                        end do
                                    end do
                                else
                                    print *, err, err_inpnn, "global_nodes_electrostatic key needs ", maxnum_layers_elec-1, " arguments"; stop
                                end if
                            end if

                        !case ('global_nodes_short_pair')
                            !print *, err, err_inpnn, "global_nodes_short_pair key is obsolete, please use global_nodes_pair instead"; stop

                        !case ('global_nodes_pair')
                            !print *, err, err_inpnn, "global_nodes_pair key not supported, Pair NN not implemented"; stop

                        case ('global_output_nodes_short')
                            print *, err, err_inpnn, "global_output_nodes_short key is obsolete, please remove it"; stop

                        case ('global_output_nodes_electrostatic')
                            print *, err, err_inpnn, "global_output_nodes_electrostatic key is obsolete, please remove it"; stop

                        case ('global_output_nodes_pair')
                            print *, err, err_inpnn, "global_output_nodes_pair key is obsolete, please remove it"; stop

                        case ('ewald_alpha')
                            if (ewaldalpha /= default_real) stop err // err_inpnn // 'Multiple use of the ewald_alpha key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) ewaldalpha
                                if (ios /= 0) stop err // err_inpnn // "ewald_alpha value must be a number"
                            else
                                print *, err, err_inpnn, "ewald_alpha key needs a single argument"; stop
                            end if

                        case ('ewald_cutoff')
                            if (ewaldcutoff /= default_real) stop err // err_inpnn // 'Multiple use of the ewald_cutoff key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) ewaldcutoff
                                if (ios /= 0) stop err // err_inpnn // "ewald_cutoff value must be a number"
                            else
                                print *, err, err_inpnn, "ewald_cutoff key needs a single argument"; stop
                            end if

                        case ('ewald_kmax')
                            if (ewaldkmax /= default_int) stop err // err_inpnn // 'Multiple use of the ewald_kmax key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) ewaldkmax
                                if (ios /= 0) stop err // err_inpnn // "ewald_kmax value must be integer"
                            else
                                print *, err, err_inpnn, "ewald_kmax key needs a single argument"; stop
                            end if

                        case ('precondition_weights')
                            if (lprecond /= default_bool) stop err // err_inpnn // 'Multiple use of the precondition_weights key'
                            if (nwords == 1) then
                                lprecond = .true.
                            else
                                print *, err, err_inpnn, "precondition_weights key needs no argument(s)"; stop
                            end if

                        case ('initialization_only')
                            if (linionly /= default_bool) stop err // err_inpnn // 'Multiple use of the initialization_only key'
                            if (nwords == 1) then
                                linionly = .true.
                            else
                                print *, err, err_inpnn, "initialization_only key needs no argument(s)"; stop
                            end if

                        case ('force_grouping_by_structure')
                            if (lfgroupbystruct /= default_bool) stop err // err_inpnn // 'Multiple use of the force_grouping_by_structure key'
                            if (nwords == 1) then
                                lfgroupbystruct = .true.
                            else
                                print *, err, err_inpnn, "force_grouping_by_structure key needs no argument(s)"; stop
                            end if

                        case ('charge_grouping_by_structure')
                            if (lqgroupbystruct /= default_bool) stop err // err_inpnn // 'Multiple use of the charge_grouping_by_structure key'
                            if (nwords == 1) then
                                lqgroupbystruct = .true.
                            else
                                print *, err, err_inpnn, "charge_grouping_by_structure key needs no argument(s)"; stop
                            end if

                        case ('mix_all_points')
                            if (lmixpoints /= default_bool) stop err // err_inpnn // 'Multiple use of the mix_all_points key'
                            if (nwords == 1) then
                                lmixpoints = .true.
                            else
                                print *, err, err_inpnn, "mix_all_points key needs no argument(s)"; stop
                            end if

                        case ('print_convergence_vector')
                            if (lprintconv /= default_bool) stop err // err_inpnn // 'Multiple use of the print_convergence_vector key'
                            if (nwords == 1) then
                                lprintconv = .true.
                            else
                                print *, err, err_inpnn, "print_convergence_vector key needs no argument(s)"; stop
                            end if

                        case ('print_mad')
                            if (lprintmad /= default_bool) stop err // err_inpnn // 'Multiple use of the print_mad key'
                            if (nwords == 1) then
                                lprintmad = .true.
                            else
                                print *, err, err_inpnn, "print_mad key needs no argument(s)"; stop
                            end if

                        case ('noise_energy')
                            if (noisee /= default_real) stop err // err_inpnn // 'Multiple use of the noise_energy key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) noisee
                                if (ios /= 0) stop err // err_inpnn // "noise_energy value must be a number"
                            else
                                print *, err, err_inpnn, "noise_energy key needs a single argument"; stop
                            end if

                        case ('noise_force')
                            if (noisef /= default_real) stop err // err_inpnn // 'Multiple use of the noise_force key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) noisef
                                if (ios /= 0) stop err // err_inpnn // "noise_force value must be a number"
                            else
                                print *, err, err_inpnn, "noise_force key needs a single argument"; stop
                            end if

                        case ('noise_charge')
                            if (noiseq /= default_real) stop err // err_inpnn // 'Multiple use of the noise_charge key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) noiseq
                                if (ios /= 0) stop err // err_inpnn // "noise_charge value must be a number"
                            else
                                print *, err, err_inpnn, "noise_charge key needs a single argument"; stop
                            end if

                        case ('short_energy_group')
                            if (nenergygroup /= default_int) stop err // err_inpnn // 'Multiple use of the short_energy_group key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) nenergygroup
                                if (ios /= 0) stop err // err_inpnn // "short_energy_group value must be integer"
                            else
                                print *, err, err_inpnn, "short_energy_group key needs a single argument"; stop
                            end if

                        case ('short_force_group')
                            if (nforcegroup /= default_int) stop err // err_inpnn // 'Multiple use of the short_force_group key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) nforcegroup
                                if (ios /= 0) stop err // err_inpnn // "short_force_group value must be integer"
                            else
                                print *, err, err_inpnn, "short_force_group key needs a single argument"; stop
                            end if

                        case ('charge_group')
                            if (nchargegroup /= default_int) stop err // err_inpnn // 'Multiple use of the charge_group key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) nchargegroup
                                if (ios /= 0) stop err // err_inpnn // "charge_group value must be integer"
                            else
                                print *, err, err_inpnn, "charge_group key needs a single argument"; stop
                            end if

                       case ('use_short_forces')
                            if (luseforces /= default_bool) stop err // err_inpnn // 'Multiple use of the use_short_forces key'
                            if (nwords == 1) then
                                luseforces = .true.
                            else
                                print *, err, err_inpnn, "use_short_forces key needs no argument(s)"; stop
                            end if

                        case ('short_energy_fraction')
                            if (energyrnd /= default_real) stop err // err_inpnn // 'Multiple use of the short_energy_fraction key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) energyrnd
                                if (ios /= 0) stop err // err_inpnn // "short_energy_fraction value must be a number"
                            else
                                print *, err, err_inpnn, "short_energy_fraction key needs a single argument"; stop
                            end if

                        case ('short_force_fraction')
                            if (forcernd /= default_real) stop err // err_inpnn // 'Multiple use of the short_force_fraction key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) forcernd
                                if (ios /= 0) stop err // err_inpnn // "short_force_fraction value must be a number"
                            else
                                print *, err, err_inpnn, "short_force_fraction key needs a single argument"; stop
                            end if

                        case ('charge_fraction')
                            if (chargernd /= default_real) stop err // err_inpnn // 'Multiple use of the charge_fraction key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) chargernd
                                if (ios /= 0) stop err // err_inpnn // "charge_fraction value must be a number"
                            else
                                print *, err, err_inpnn, "charge_fraction key needs a single argument"; stop
                            end if

                        case ('use_atom_charges')
                            ! let it pass, since done before
                            !if (luseatomcharges /= default_bool) stop err // err_inpnn // 'Multiple use of the use_atom_charges key'
                            !if (nwords == 1) then
                            !    luseatomcharges = .true.
                            !else
                            !    print *, err, err_inpnn, "use_atom_charges key needs no argument(s)"; stop
                            !end if

                        case ('use_atom_energies')
                            ! let it pass, since done before
                            !if (luseatomenergies /= default_bool) stop err // err_inpnn // 'Multiple use of the use_atom_energies key'
                            !if (nwords == 1) then
                            !    luseatomenergies = .true.
                            !else
                            !    print *, err, err_inpnn, "use_atom_energies key needs no argument(s)"; stop
                            !end if

                        case ('remove_atom_energies')
                            if (lremoveatomenergies /= default_bool) stop err // err_inpnn // 'Multiple use of the remove_atom_energies key'
                            if (nwords == 1) then
                                lremoveatomenergies = .true.
                            else
                                print *, err, err_inpnn, "remove_atom_energies key needs no argument(s)"; stop
                            end if

                        case ('analyze_error')
                            if (lanalyzeerror /= default_bool) stop err // err_inpnn // 'Multiple use of the analyze_error key'
                            if (nwords == 1) then
                                lanalyzeerror = .true.
                            else
                                print *, err, err_inpnn, "analyze_error key needs no argument(s)"; stop
                            end if

                        case ('use_charge_constraint')
                            if (lchargeconstraint /= default_bool) stop err // err_inpnn // 'Multiple use of the use_charge_constraint key'
                            if (nwords == 1) then
                                lchargeconstraint = .true.
                            else
                                print *, err, err_inpnn, "use_charge_constraint key needs no argument(s)"; stop
                            end if

                        case ('fitmode')
                            if (fitmode /= default_int) stop err // err_inpnn // 'Multiple use of the fitmode key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) fitmode
                                if (ios /= 0) stop err // err_inpnn // "fitmode value must be integer"

                                select case (words(2))

                                    case ('1', '2')
                                        ! Just let it pass

                                    case default
                                        print *, err, err_inpnn, "Error in fitmode key value, only 1 and 2 possible"
                                        stop

                                end select

                            else
                                print *, err, err_inpnn, "fitmode key needs a single argument"; stop
                            end if

                        case ('energy_threshold')
                            if (fitethres /= default_real) stop err // err_inpnn // 'Multiple use of the energy_threshold key'
                            if (nwords == 2) then
                                lfitethres = .true.
                                read(words(2),*, iostat=ios) fitethres
                                if (ios /= 0) stop err // err_inpnn // "energy_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "energy_threshold key needs a single argument"; stop
                            end if

                        case ('force_threshold')
                            if (fitfthres /= default_real) stop err // err_inpnn // 'Multiple use of the force_threshold key'
                            if (nwords == 2) then
                                lfitfthres = .true.
                                read(words(2),*, iostat=ios) fitfthres
                                if (ios /= 0) stop err // err_inpnn // "force_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "force_threshold key needs a single argument"; stop
                            end if

                       case ('bond_threshold')
                            if (rmin /= default_real) stop err // err_inpnn // 'Multiple use of the bond_threshold key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) rmin
                                if (ios /= 0) stop err // err_inpnn // "bond_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "bond_threshold key needs a single argument"; stop
                            end if

                        case ('optmode_short_energy')
                            if (optmodee /= default_int) stop err // err_inpnn // 'Multiple use of the optmode_short_energy key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) optmodee
                                if (ios /= 0) stop err // err_inpnn // "optmode_short_energy value must be integer"
                            else
                                print *, err, err_inpnn, "optmode_short_energy key needs a single argument"; stop
                            end if

                        case ('optmode_short_force')
                            if (optmodef /= default_int) stop err // err_inpnn // 'Multiple use of the optmode_short_force key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) optmodef
                                if (ios /= 0) stop err // err_inpnn // "optmode_short_force value must be integer"
                            else
                                print *, err, err_inpnn, "optmode_short_force key needs a single argument"; stop
                            end if

                        case ('optmode_charge')
                            if (optmodeq /= default_int) stop err // err_inpnn // 'Multiple use of the optmode_charge key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) optmodeq
                                if (ios /= 0) stop err // err_inpnn // "optmode_charge value must be integer"
                            else
                                print *, err, err_inpnn, "optmode_charge key needs a single argument"; stop
                            end if

                        case ('random_seed')
                            if (iseed /= default_int) stop err // err_inpnn // 'Multiple use of the random_seed key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) iseed
                                if (ios /= 0) stop err // err_inpnn // "random_seed value must be integer"
                            else
                                print *, err, err_inpnn, "random_seed key needs a single argument"; stop
                            end if

                        case ('points_in_memory', 'nblock') ! think about to set it according to number of atoms from structure file
                            if (nblock /= default_int) stop err // err_inpnn // 'Multiple use of the points_in_memory/nblock key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) nblock
                                if (ios /= 0) stop err // err_inpnn // "points_in_memory/nblock value must be integer"
                            else
                                print *, err, err_inpnn, "points_in_memory/nblock key needs a single argument"; stop
                            end if

                        case ('epochs')
                            if (nepochs /= default_int) stop err // err_inpnn // 'Multiple use of the epochs key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) nepochs
                                if (ios /= 0) stop err // err_inpnn // "epochs value must be integer"
                            else
                                print *, err, err_inpnn, "epochs key needs a single argument"; stop
                            end if

                        case ('write_weights_epoch')
                            if (iwriteweight /= default_int) stop err // err_inpnn // 'Multiple use of the write_weights_epoch key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) iwriteweight
                                if (ios /= 0) stop err // err_inpnn // "write_weights_epoch value must be integer"
                            else
                                print *, err, err_inpnn, "write_weights_epoch key needs a single argument"; stop
                            end if

                        case ('write_temporary_weights')
                            if (lwritetmpweights /= default_bool) stop err // err_inpnn // 'Multiple use of the write_temporary_weights key'
                            if (nwords == 1) then
                                lwritetmpweights = .true.
                            else
                                print *, err, err_inpnn, "write_temporary_weights key needs no argument(s)"; stop
                            end if

                        case ('write_symfunctions')
                            if (lwritesymfunctions /= default_bool) stop err // err_inpnn // 'Multiple use of the write_symfunctions key'
                            if (nwords == 1) then
                                lwritesymfunctions = .true.
                            else
                                print *, err, err_inpnn, "write_symfunctions key needs no argument(s)"; stop
                            end if

                        case ('test_fraction')
                            if (splitthres /= default_real) stop err // err_inpnn // 'Multiple use of the test_fraction key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) splitthres
                                if (ios /= 0) stop err // err_inpnn // "test_fraction value must be a number"
                            else
                                print *, err, err_inpnn, "test_fraction key needs a single argument"; stop
                            end if

                        case ('scale_min_short_atomic')
                            if (scmin_short_atomic /= default_real) stop err // err_inpnn // 'Multiple use of the scale_min_short_atomic key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) scmin_short_atomic
                                if (ios /= 0) stop err // err_inpnn // "scale_min_short_atomic value must be a number"
                            else
                                print *, err, err_inpnn, "scale_min_short_atomic key needs a single argument"; stop
                            end if

                        case ('scale_max_short_atomic')
                            if (scmax_short_atomic /= default_real) stop err // err_inpnn // 'Multiple use of the scale_max_short_atomic key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) scmax_short_atomic
                                if (ios /= 0) stop err // err_inpnn // "scale_max_short_atomic value must be a number"
                            else
                                print *, err, err_inpnn, "scale_max_short_atomic key needs a single argument"; stop
                            end if

                        case ('scale_min_short_pair')
                            print *, err, err_inpnn, "scale_min_short_pair key not supported, Pair NN not implemented"; stop

                        case ('scale_max_short_pair')
                            print *, err, err_inpnn, "scale_max_short_pair key not supported, Pair NN not implemented"; stop

                        case ('scale_min_elec')
                            if (scmin_elec /= default_real) stop err // err_inpnn // 'Multiple use of the scale_min_elec key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) scmin_elec
                                if (ios /= 0) stop err // err_inpnn // "scale_min_elec value must be a number"
                            else
                                print *, err, err_inpnn, "scale_min_elec key needs a single argument"; stop
                            end if

                        case ('scale_max_elec')
                            if (scmax_elec /= default_real) stop err // err_inpnn // 'Multiple use of the scale_max_elec key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) scmax_elec
                                if (ios /= 0) stop err // err_inpnn // "scale_max_elec value must be a number"
                            else
                                print *, err, err_inpnn, "scale_max_elec key needs a single argument"; stop
                            end if

                        case ('short_energy_error_threshold')
                            if (kalmanthreshold /= default_real) stop err // err_inpnn // 'Multiple use of the short_energy_error_threshold key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmanthreshold
                                if (ios /= 0) stop err // err_inpnn // "short_energy_error_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "short_energy_error_threshold key needs a single argument"; stop
                            end if

                        case ('short_force_error_threshold')
                            if (kalmanthresholdf /= default_real) stop err // err_inpnn // 'Multiple use of the short_force_error_threshold key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmanthresholdf
                                if (ios /= 0) stop err // err_inpnn // "short_force_error_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "short_force_error_threshold key needs a single argument"; stop
                            end if

                        case ('charge_error_threshold')
                            if (kalmanthresholde /= default_real) stop err // err_inpnn // 'Multiple use of the charge_error_threshold key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmanthresholde
                                if (ios /= 0) stop err // err_inpnn // "charge_error_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "charge_error_threshold key needs a single argument"; stop
                            end if

                        case ('total_charge_error_threshold')
                            if (kalmanthresholdc /= default_real) stop err // err_inpnn // 'Multiple use of the total_charge_error_threshold key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmanthresholdc
                                if (ios /= 0) stop err // err_inpnn // "total_charge_error_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "total_charge_error_threshold key needs a single argument"; stop
                            end if

                        case ('kalman_damp_short')
                            if (kalman_dampe /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_damp_short key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalman_dampe
                                if (ios /= 0) stop err // err_inpnn // "kalman_damp_short value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_damp_short key needs a single argument"; stop
                            end if

                        case ('kalman_damp_force')
                            if (kalman_dampf /= default_real) stop err // err_inpnn // 'Multiple use of thekalman_damp_force  key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalman_dampf
                                if (ios /= 0) stop err // err_inpnn // "kalman_damp_force value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_damp_force key needs a single argument"; stop
                            end if

                        case ('kalman_damp_charge')
                            if (kalman_dampq /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_damp_charge key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalman_dampq
                                if (ios /= 0) stop err // err_inpnn // "kalman_damp_charge value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_damp_charge key needs a single argument"; stop
                            end if

                        case ('kalman_lambda_short')
                            if (kalmanlambda_local /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_lambda_short key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmanlambda_local
                                if (ios /= 0) stop err // err_inpnn // "kalman_lambda_short value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_lambda_short key needs a single argument"; stop
                            end if

                        case ('kalman_lambda_charge')
                            if (kalmanlambdae_local /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_lambda_charge key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmanlambdae_local
                                if (ios /= 0) stop err // err_inpnn // "kalman_lambda_charge value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_lambda_charge key needs a single argument"; stop
                            end if

                        case ('kalman_lambda_charge_constraint')
                            if (kalmanlambdac /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_lambda_charge_constraint key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmanlambdac
                                if (ios /= 0) stop err // err_inpnn // "kalman_lambda_charge_constraint value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_lambda_charge_constraint key needs a single argument"; stop
                            end if

                        case ('kalman_nue_short')
                            if (kalmannue /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_nue_short key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmannue
                                if (ios /= 0) stop err // err_inpnn // "kalman_nue_short value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_nue_short key needs a single argument"; stop
                            end if

                        case ('kalman_nue_charge')
                            if (kalmannuee /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_nue_charge key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmannuee
                                if (ios /= 0) stop err // err_inpnn // "kalman_nue_charge value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_nue_charge key needs a single argument"; stop
                            end if

                        case ('kalman_nue_charge_constraint')
                            if (kalmannuec /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_nue_charge_constraint key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalmannuec
                                if (ios /= 0) stop err // err_inpnn // "kalman_nue_charge_constraint value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_nue_charge_constraint key needs a single argument"; stop
                            end if

                        case ('use_noisematrix')
                            if (lusenoisematrix /= default_bool) stop err // err_inpnn // 'Multiple use of the use_noisematrix key'
                            if (nwords == 1) then
                                lusenoisematrix = .true.
                            else
                                print *, err, err_inpnn, "use_noisematrix key needs no argument(s)"; stop
                            end if

                        case ('kalman_q0')
                            if (kalman_q0 /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_q0 key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalman_q0
                                if (ios /= 0) stop err // err_inpnn // "kalman_q0 value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_q0 key needs a single argument"; stop
                            end if

                        case ('kalman_qtau')
                            if (kalman_qtau /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_qtau key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalman_qtau
                                if (ios /= 0) stop err // err_inpnn // "kalman_qtau value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_qtau key needs a single argument"; stop
                            end if

                       case ('kalman_qmin')
                            if (kalman_qmin /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_qmin key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalman_qmin
                                if (ios /= 0) stop err // err_inpnn // "kalman_qmin value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_qmin key needs a single argument"; stop
                            end if

                        case ('kalman_epsilon')
                            if (kalman_epsilon /= default_real) stop err // err_inpnn // 'Multiple use of the kalman_epsilon key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) kalman_epsilon
                                if (ios /= 0) stop err // err_inpnn // "kalman_epsilon value must be a number"
                            else
                                print *, err, err_inpnn, "kalman_epsilon key needs a single argument"; stop
                            end if

                        case ('steepest_descent_step_energy_short')
                            if (steepeststepe /= default_real) stop err // err_inpnn // 'Multiple use of the steepest_descent_step_energy_short key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) steepeststepe
                                if (ios /= 0) stop err // err_inpnn // "steepest_descent_step_energy_short value must be a number"
                            else
                                print *, err, err_inpnn, "steepest_descent_step_energy_short key needs a single argument"; stop
                            end if

                       case ('steepest_descent_step_force_short')
                            if (steepeststepf /= default_real) stop err // err_inpnn // 'Multiple use of the steepest_descent_step_force_short key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) steepeststepf
                                if (ios /= 0) stop err // err_inpnn // "steepest_descent_step_force_short value must be a number"
                            else
                                print *, err, err_inpnn, "steepest_descent_step_force_short key needs a single argument"; stop
                            end if

                        case ('steepest_descent_step_charge')
                            if (steepeststepq /= default_real) stop err // err_inpnn // 'Multiple use of the steepest_descent_step_charge key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) steepeststepq
                                if (ios /= 0) stop err // err_inpnn // "steepest_descent_step_charge value must be a number"
                            else
                                print *, err, err_inpnn, "steepest_descent_step_charge key needs a single argument"; stop
                            end if

                        case ('force_update_scaling')
                            if (scalefactorf /= default_real) stop err // err_inpnn // 'Multiple use of the force_update_scaling key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) scalefactorf
                                if (ios /= 0) stop err // err_inpnn // "force_update_scaling value must be a number"
                            else
                                print *, err, err_inpnn, "force_update_scaling key needs a single argument"; stop
                            end if

                        case ('charge_update_scaling')
                            if (scalefactorq /= default_real) stop err // err_inpnn // 'Multiple use of the charge_update_scaling key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) scalefactorq
                                if (ios /= 0) stop err // err_inpnn // "charge_update_scaling value must be a number"
                            else
                                print *, err, err_inpnn, "charge_update_scaling key needs a single argument"; stop
                            end if

                        case ('random_order_training')
                            print *, err, err_inpnn, "random_order_training key is obsolete, please use mix_all_points instead"; stop

                        case ('scale_symmetry_functions')
                            if (lscalesym /= default_bool) stop err // err_inpnn // 'Multiple use of the scale_symmetry_functions key'
                            if (nwords == 1) then
                                lscalesym = .true.
                            else
                                print *, err, err_inpnn, "scale_symmetry_functions key needs no argument(s)"; stop
                            end if

                        case ('center_symmetry_functions')
                            if (lcentersym /= default_bool) stop err // err_inpnn // 'Multiple use of the center_symmetry_functions key'
                            if (nwords == 1) then
                                lcentersym = .true.
                            else
                                print *, err, err_inpnn, "center_symmetry_functions key needs no argument(s)"; stop
                            end if

                        case ('use_old_weights_short')
                            if (luseoldweightsshort /= default_bool) stop err // err_inpnn // 'Multiple use of the use_old_weights_short key'
                            if (nwords == 1) then
                                luseoldweightsshort = .true.
                            else
                                print *, err, err_inpnn, "use_old_weights_short key needs no argument(s)"; stop
                            end if

                        case ('use_old_weights_charge')
                            if (luseoldweightscharge /= default_bool) stop err // err_inpnn // 'Multiple use of the use_old_weights_charge key'
                            if (nwords == 1) then
                                luseoldweightscharge = .true.
                            else
                                print *, err, err_inpnn, "use_old_weights_charge key needs no argument(s)"; stop
                            end if

                        case ('save_kalman_matrices')
                            if (lsavekalman /= default_bool) stop err // err_inpnn // 'Multiple use of the save_kalman_matrices key'
                            if (nwords == 1) then
                                lsavekalman = .true.
                            else
                                print *, err, err_inpnn, "save_kalman_matrices key needs no argument(s)"; stop
                            end if

                        case ('read_kalman_matrices')
                            if (lrestkalman /= default_bool) stop err // err_inpnn // 'Multiple use of the read_kalman_matrices key'
                            if (nwords == 1) then
                                lrestkalman = .true.
                            else
                                print *, err, err_inpnn, "read_kalman_matrices key needs no argument(s)"; stop
                            end if

                        case ('update_single_element')
                            if (lupdatebyelement /= default_bool) stop err // err_inpnn // 'Multiple use of the update_single_element key'
                            if (nwords == 2) then
                                lupdatebyelement = .true.
                                read(words(2),'(i1000)', iostat=ios) elemupdate
                                if (ios /= 0) stop err // err_inpnn // "update_single_element value must be integer"
                            else
                                print *, err, err_inpnn, "update_single_element key needs a single argument"; stop
                            end if

                        case ('update_worst_short_energies')
                            if (luseworste /= default_bool) stop err // err_inpnn // 'Multiple use of the update_worst_short_energies key'
                            if (nwords == 2) then
                                luseworste = .true.
                                read(words(2),*, iostat=ios) worste
                                if (ios /= 0) stop err // err_inpnn // "update_worst_short_energies value must be a number"
                            else
                                print *, err, err_inpnn, "update_worst_short_energies key needs a single argument"; stop
                            end if

                        case ('update_worst_short_forces')
                            if (luseworstf /= default_bool) stop err // err_inpnn // 'Multiple use of the update_worst_short_forces key'
                            if (nwords == 2) then
                                luseworstf = .true.
                                read(words(2),*, iostat=ios) worstf
                                if (ios /= 0) stop err // err_inpnn // "update_worst_short_forces value must be a number"
                            else
                                print *, err, err_inpnn, "update_worst_short_forces key needs a single argument"; stop
                            end if

                        case ('update_worst_charges')
                            if (luseworstq /= default_bool) stop err // err_inpnn // 'Multiple use of the update_worst_charges key'
                            if (nwords == 2) then
                                luseworstq = .true.
                                read(words(2),*, iostat=ios) worstq
                                if (ios /= 0) stop err // err_inpnn // "update_worst_charges value must be a number"
                            else
                                print *, err, err_inpnn, "update_worst_charges key needs a single argument"; stop
                            end if

                        case ('growth_mode')
                            if (lgrowth /= default_bool) stop err // err_inpnn // 'Multiple use of the growth_mode key'
                            if (nwords == 3) then
                                lgrowth = .true.
                                read(words(2),'(i1000)', iostat=ios) ngrowth
                                if (ios /= 0) stop err // err_inpnn // "growth_mode first argument value must be integer"
                                read(words(3),'(i1000)', iostat=ios) growthstep
                                if (ios /= 0) stop err // err_inpnn // "growth_mode second argument must be integer"
                            else
                                print *, err, err_inpnn, "growth_mode key needs a single argument"; stop
                            end if

                        case ('use_damping')
                            if (ldampw /= default_bool) stop err // err_inpnn // 'Multiple use of the use_damping key'
                            if (nwords == 2) then
                                ldampw = .true.
                                read(words(2),*, iostat=ios) dampw
                                if (ios /= 0) stop err // err_inpnn // "use_damping value must be a number"
                            else
                                print *, err, err_inpnn, "use_damping key needs a single argument"; stop
                            end if

                        case ('fix_weights')
                            if (lfixweights /= default_bool) stop err // err_inpnn // 'Multiple use of the fix_weights key'
                            if (nwords == 1) then
                                lfixweights = .true.
                            else
                                print *, err, err_inpnn, "fix_weights key needs no argument(s)"; stop
                            end if

                        case ('calculate_forces')
                            if (ldoforces /= default_bool) stop err // err_inpnn // 'Multiple use of the calculate_forces key'
                            if (nwords == 1) then
                                ldoforces = .true.
                            else
                                print *, err, err_inpnn, "calculate_forces key needs no argument(s)"; stop
                            end if

                        case ('calculate_hessian')
                            if (ldohessian /= default_bool) stop err // err_inpnn // 'Multiple use of the calculate_hessian key'
                            if (nwords == 1) then
                                ldohessian = .true.
                            else
                                print *, err, err_inpnn, "calculate_hessian key needs no argument(s)"; stop
                            end if

                        case ('calculate_stress')
                            if (ldostress /= default_bool) stop err // err_inpnn // 'Multiple use of the calculate_stress key'
                            if (nwords == 1) then
                                ldostress = .true.
                            else
                                print *, err, err_inpnn, "calculate_stress key needs no argument(s)"; stop
                            end if

                        case ('enforce_max_num_neighbors_atomic')
                            if (max_num_neighbors_atomic_input /= default_int) stop err // err_inpnn // 'Multiple use of the enforce_max_num_neighbors_atomic key'
                            if (nwords == 2) then
                                lenforcemaxnumneighborsatomic = .true.
                                read(words(2),'(i1000)', iostat=ios) max_num_neighbors_atomic_input
                                if (ios /= 0) stop err // err_inpnn // "enforce_max_num_neighbors_atomic value must be integer"
                            else
                                print *, err, err_inpnn, "enforce_max_num_neighbors_atomic key needs a single argument"; stop
                            end if

                        case ('detailed_timing')
                            if (lfinetime /= default_bool) stop err // err_inpnn // 'Multiple use of the detailed_timing key'
                            if (nwords == 1) then
                                lfinetime = .true.
                            else
                                print *, err, err_inpnn, "detailed_timing key needs no argument(s)"; stop
                            end if

                        case ('detailed_timing_epoch')
                            if (lfinetimeepoch /= default_bool) stop err // err_inpnn // 'Multiple use of the detailed_timing_epoch key'
                            if (nwords == 1) then
                                lfinetimeepoch = .true.
                            else
                                print *, err, err_inpnn, "detailed_timing_epoch key needs no argument(s)"; stop
                            end if

                        case ('write_pdb')
                            print *, err, err_inpnn, "write_pdb key is obsolete, please remove it"; stop

                        case ('write_xyz')
                            print *, err, err_inpnn, "write_xyz key is obsolete, please remove it"; stop

                        case ('write_pov')
                            print *, err, err_inpnn, "write_pov key is obsolete, please remove it"; stop

                        case ('write_pwscf')
                            print *, err, err_inpnn, "write_pwscf key is obsolete, please remove it"; stop

                        case ('write_trainpoints')
                            if (lwritetrainpoints /= default_bool) stop err // err_inpnn // 'Multiple use of the write_trainpoints key'
                            if (nwords == 1) then
                                lwritetrainpoints = .true.
                            else
                                print *, err, err_inpnn, "write_trainpoints key needs no argument(s)"; stop
                            end if

                        case ('write_trainforces')
                            if (lwritetrainforces /= default_bool) stop err // err_inpnn // 'Multiple use of the write_trainforces key'
                            if (nwords == 1) then
                                lwritetrainforces = .true.
                            else
                                print *, err, err_inpnn, "write_trainforces key needs no argument(s)"; stop
                            end if

                        case ('write_traincharges')
                            if (lwritetraincharges /= default_bool) stop err // err_inpnn // 'Multiple use of the write_traincharges key'
                            if (nwords == 1) then
                                lwritetraincharges = .true.
                            else
                                print *, err, err_inpnn, "write_traincharges key needs no argument(s)"; stop
                            end if

                        case ('max_force')
                            if (maxforce /= default_real) stop err // err_inpnn // 'Multiple use of the max_force key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) maxforce
                                if (ios /= 0) stop err // err_inpnn // "max_force value must be a number"
                            else
                                print *, err, err_inpnn, "max_force key needs a single argument"; stop
                            end if

                        case ('max_energy')
                            if (maxenergy /= default_real) stop err // err_inpnn // 'Multiple use of the max_energy key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) maxenergy
                                if (ios /= 0) stop err // err_inpnn // "max_energy value must be a number"
                            else
                                print *, err, err_inpnn, "max_energy key needs a single argument"; stop
                            end if

                        case ('nn_type')
                            print *, err, err_inpnn, "nn_type key is obsolete, please use nn_type_short instead"; stop

                        case ('random_number_type')
                            if (nran /= default_int) stop err // err_inpnn // 'Multiple use of the random_number_type key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) nran
                                if (ios /= 0) stop err // err_inpnn // "random_number_type value must be integer"
                            else
                                print *, err, err_inpnn, "random_number_type key needs a single argument"; stop
                            end if

                        case ('calculate_final_force')
                            if (lfinalforce /= default_bool) stop err // err_inpnn // 'Multiple use of the calculate_final_force key'
                            if (nwords == 1) then
                                lfinalforce = .true.
                            else
                                print *, err, err_inpnn, "calculate_final_force key needs no argument(s)"; stop
                            end if

                        case ('normalize_nodes')
                            if (lnormnodes /= default_bool) stop err // err_inpnn // 'Multiple use of the normalize_nodes key'
                            if (nwords == 1) then
                                lnormnodes = .true.
                            else
                                print *, err, err_inpnn, "normalize_nodes key needs no argument(s)"; stop
                            end if

                        case ('atom_energy')
                            ! just let it pass

                        case ('weight_constraint')
                            count_wconstraint=count_wconstraint+1
                            ! just let it pass

                        case ('weighte_constraint')
                            count_wconstraint=count_wconstraint+1 ! same as previous?
                            ! just let it pass

                        case ('weights_min')
                            if (weights_min /= default_real) stop err // err_inpnn // 'Multiple use of the weights_min key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) weights_min
                                if (ios /= 0) stop err // err_inpnn // "weights_min value must be a number"
                            else
                                print *, err, err_inpnn, "weights_min key needs a single argument"; stop
                            end if

                        case ('weights_max')
                            if (weights_max /= default_real) stop err // err_inpnn // 'Multiple use of the weights_max key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) weights_max
                                if (ios /= 0) stop err // err_inpnn // "weights_max value must be a number"
                            else
                                print *, err, err_inpnn, "weights_max key needs a single argument"; stop
                            end if

                        case ('separate_bias_ini_short')
                            if (lseparatebiasini /= default_bool) stop err // err_inpnn // 'Multiple use of the separate_bias_ini_short key'
                            if (nwords == 1) then
                                lseparatebiasini = .true.
                            else
                                print *, err, err_inpnn, "separate_bias_ini_short key needs no argument(s)"; stop
                            end if

                        case ('biasweights_min')
                            if (biasweights_min /= default_real) stop err // err_inpnn // 'Multiple use of the biasweights_min key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) biasweights_min
                                if (ios /= 0) stop err // err_inpnn // "biasweights_min value must be a number"
                            else
                                print *, err, err_inpnn, "biasweights_min key needs a single argument"; stop
                            end if

                        case ('biasweights_max')
                            if (biasweights_max /= default_real) stop err // err_inpnn // 'Multiple use of the biasweights_max key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) biasweights_max
                                if (ios /= 0) stop err // err_inpnn // "biasweights_max value must be a number"
                            else
                                print *, err, err_inpnn, "biasweights_max key needs a single argument"; stop
                            end if

                        case ('weightse_min')
                            if (weightse_min /= default_real) stop err // err_inpnn // 'Multiple use of the weightse_min key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) weightse_min
                                if (ios /= 0) stop err // err_inpnn // "weightse_min value must be a number"
                            else
                                print *, err, err_inpnn, "weightse_min key needs a single argument"; stop
                            end if

                        case ('weightse_max')
                            if (weightse_max /= default_real) stop err // err_inpnn // 'Multiple use of the weightse_max key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) weightse_max
                                if (ios /= 0) stop err // err_inpnn // "weightse_max value must be a number"
                            else
                                print *, err, err_inpnn, "weightse_max key needs a single argument"; stop
                            end if

                        case ('use_systematic_weights_short')
                            if (lsysweights /= default_bool) stop err // err_inpnn // 'Multiple use of the use_systematic_weights_short key'
                            if (nwords == 1) then
                                lsysweights = .true.
                            else
                                print *, err, err_inpnn, "use_systematic_weights_short key needs no argument(s)"; stop
                            end if

                        case ('use_systematic_weights_electrostatic')
                            if (lsysweightse /= default_bool) stop err // err_inpnn // 'Multiple use of the use_systematic_weights_electrostatic key'
                            if (nwords == 1) then
                                lsysweightse = .true.
                            else
                                print *, err, err_inpnn, "use_systematic_weights_electrostatic key needs no argument(s)"; stop
                            end if

                        case ('print_sensitivity')
                            if (lsens /= default_bool) stop err // err_inpnn // 'Multiple use of the print_sensitivity key'
                            if (nwords == 1) then
                                lsens = .true.
                            else
                                print *, err, err_inpnn, "print_sensitivity key needs no argument(s)"; stop
                            end if

                        case ('read_unformatted')
                            if (lreadunformatted /= default_bool) stop err // err_inpnn // 'Multiple use of the read_unformatted key'
                            if (nwords == 1) then
                                lreadunformatted = .true.
                            else
                                print *, err, err_inpnn, "read_unformatted key needs no argument(s)"; stop
                            end if

                        case ('write_unformatted')
                            if (lwriteunformatted /= default_bool) stop err // err_inpnn // 'Multiple use of the write_unformatted key'
                            if (nwords == 1) then
                                lwriteunformatted = .true.
                            else
                                print *, err, err_inpnn, "write_unformatted key needs no argument(s)"; stop
                            end if

                        case ('reset_kalman')
                            if (lresetkalman /= default_bool) stop err // err_inpnn // 'Multiple use of the reset_kalman key'
                            if (nwords == 1) then
                                lresetkalman = .true.
                            else
                                print *, err, err_inpnn, "reset_kalman key needs no argument(s)"; stop
                            end if

                        case ('separate_kalman_short')
                            if (lsepkalman /= default_bool) stop err // err_inpnn // 'Multiple use of the separate_kalman_short key'
                            if (nwords == 1) then
                                lsepkalman = .true.
                            else
                                print *, err, err_inpnn, "separate_kalman_short key needs no argument(s)"; stop
                            end if

                        case ('repeated_energy_update')
                            if (lrepeate /= default_bool) stop err // err_inpnn // 'Multiple use of the repeated_energy_update key'
                            if (nwords == 1) then
                                lrepeate = .true.
                            else
                                print *, err, err_inpnn, "repeated_energy_update key needs no argument(s)"; stop
                            end if

                        case ('enforce_totcharge')
                            if (enforcetotcharge /= default_int) stop err // err_inpnn // 'Multiple use of the enforce_totcharge key'
                            if (nwords == 2) then
                                read(words(2),'(i1000)', iostat=ios) enforcetotcharge
                                if (ios /= 0) stop err // err_inpnn // "enforce_totcharge value must be integer"
                            else
                                print *, err, err_inpnn, "enforce_totcharge key needs a single argument"; stop
                            end if

                        case ('shuffle_weights_short_atomic')
                            if (lshuffle_weights_short_atomic /= default_bool) stop err // err_inpnn // 'Multiple use of the shuffle_weights_short_atomic key'
                            if (nwords == 3) then
                                rin pparam%lshuffle_weights_short_atomic = .true.
                                read(words(2),'(i1000)', iostat=ios) nshuffle_weights_short_atomic
                                if (ios /= 0) stop err // err_inpnn // "shuffle_weights_short_atomic first argument value must be integer"
                                read(words(3),*, iostat=ios) shuffle_weights_short_atomic
                                if (ios /= 0) stop err // err_inpnn // "shuffle_weights_short_atomic second argument value must be a number"
                            else
                                print *, err, err_inpnn, "shuffle_weights_short_atomic key needs two arguments"; stop
                            end if

                        case ('check_forces')
                            if (lcheckf /= default_bool) stop err // err_inpnn // 'Multiple use of the check_forces key'
                            if (nwords == 1) then
                                lcheckf = .true.
                            else
                                print *, err, err_inpnn, "check_forces key needs no argument(s)"; stop
                            end if

                        case ('write_fit_statistics')
                            if (lfitstats /= default_bool) stop err // err_inpnn // 'Multiple use of the write_fit_statistics key'
                            if (nwords == 1) then
                                lfitstats = .true.
                            else
                                print *, err, err_inpnn, "write_fit_statistics key needs no argument(s)"; stop
                            end if

                        case ('fixed_short_energy_error_threshold')
                            if (lfixederrore /= default_bool) stop err // err_inpnn // 'Multiple use of the fixed_short_energy_error_threshold key'
                            if (nwords == 2) then
                                lfixederrore = .true.
                                read(words(2),*, iostat=ios) fixederrore
                                if (ios /= 0) stop err // err_inpnn // "fixed_short_energy_error_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "fixed_short_energy_error_threshold key needs a single argument"; stop
                            end if

                        case ('fixed_short_force_error_threshold')
                            if (lfixederrorf /= default_bool) stop err // err_inpnn // 'Multiple use of the fixed_short_force_error_threshold key'
                            if (nwords == 2) then
                                lfixederrorf = .true.
                                read(words(2),*, iostat=ios) fixederrorf
                                if (ios /= 0) stop err // err_inpnn // "fixed_short_force_error_threshold value must be a number"
                            else
                                print *, err, err_inpnn, "fixed_short_force_error_threshold key needs a single argument"; stop
                            end if

                        case ('restrict_weights')
                            if (restrictw /= default_real) stop err // err_inpnn // 'Multiple use of the restrict_weights key'
                            if (nwords == 2) then
                                read(words(2),*, iostat=ios) restrictw
                                if (ios /= 0) stop err // err_inpnn // "restrict_weights value must be a number"
                            else
                                print *, err, err_inpnn, "restrict_weights key needs a single argument"; stop
                            end if

                        case ('screen_electrostatics')
                            if (lscreen /= default_bool) stop err // err_inpnn // 'Multiple use of the screen_electrostatics key'
                            if (nwords == 3) then
                                lscreen = .true.
                                read(words(2),*, iostat=ios) rscreen_onset
                                if (ios /= 0) stop err // err_inpnn // "screen_electrostatics first argument value must be a number"
                                read(words(3),*, iostat=ios) rscreen_cut
                                if (ios /= 0) stop err // err_inpnn // "screen_electrostatics second argument value must be a number"
                            else
                                print *, err, err_inpnn, " key needs two arguments"; stop
                            end if

                        case ('silent_mode')
                            if (lsilent /= default_bool) stop err // err_inpnn // 'Multiple use of the silent_mode key'
                            if (nwords == 1) then
                                lsilent = .true.
                            else
                                print *, err, err_inpnn, "silent_mode key needs no argument(s)"; stop
                            end if

                        case ('prepare_md')
                            if (lpreparemd /= default_bool) stop err // err_inpnn // 'Multiple use of the prepare_md key'
                            if (nwords == 1) then
                                lpreparemd = .true.
                            else
                                print *, err, err_inpnn, "prepare_md key needs no argument(s)"; stop
                            end if

                        case ('fitting_unit')
                            if (fitting_unit /= default_int) stop err // err_inpnn // 'Multiple use of the fitting_unit'
                            if (nwords == 2) then
                                !call lower_case(words(2))

                                select case (words(2))

                                    case ('eV')
                                        fitting_unit = 1

                                    case ('Ha')
                                        fitting_unit = 2

                                    case default
                                        print *, err, err_inpnn, "Error when reading fitting_unit: unknown energy unit specified ", words(2); stop

                                end select

                            else
                                print *, err, err_inpnn, "fitting_unit key needs a single"; stop
                            end if

                        case ('global_activation_short')
                            ! just let it pass

                        case ('global_activation_electrostatic')
                            ! just let it pass

                        case ('global_activation_pair')
                            print *, err, err_inpnn, "global_activation_pair key not supported, Pair NN not implemented"; stop

                        case ('element_hidden_layers_short')
                            ! just let it pass

                        case ('element_hidden_layers_electrostatic')
                            ! just let it pass

                        case ('element_hidden_layers_pair')
                            print *, err, err_inpnn, "element_hidden_layers_pair key not supported, Pair NN not implemented"; stop

                        case ('element_nodes_short')
                            ! just let it pass

                        case ('element_nodes_electrostatic')
                            ! just let it pass

                        case ('element_nodes_pair')
                            print *, err, err_inpnn, "element_nodes_pair key not supported, Pair NN not implemented"; stop

                        case ('element_activation_short')
                            ! just let it pass

                        case ('element_activation_electrostatic')
                            ! just let it pass

                        case ('element_activation_pair')
                            print *, err, err_inpnn, "element_activation_pair key not supported, Pair NN not implemented"; stop

                        case ('joint_energy_force_update')
                            if (ljointefupdate /= default_bool) stop err // err_inpnn // 'Multiple use of the joint_energy_force_update key'
                            if (nwords == 1) then
                                ljointefupdate = .true.
                            else
                                print *, err, err_inpnn, "joint_energy_force_update key needs no argument(s)"; stop
                            end if

                        case ('use_fixed_charges')
                            print *, err, err_inpnn, "use_fixed_charges key is obsolete, please use electrostatic_type 3 instead"; stop

                        case ('use_omp_mkl')
                            if (lompmkl /= default_bool) stop err // err_inpnn // 'Multiple use of the use_omp_mkl key'
                            if (nwords == 1) then
                                lompmkl = .true.
                            else
                                print *, err, err_inpnn, "use_omp_mkl key needs no argument(s)"; stop
                            end if

                        case ('nguyen_widrow_weights_short')
                            if (lnwweights /= default_bool) stop err // err_inpnn // 'Multiple use of the nguyen_widrow_weights_short key'
                            if (nwords == 1) then
                                lnwweights = .true.
                            else
                                print *, err, err_inpnn, "nguyen_widrow_weights_short key needs no argument(s)"; stop
                            end if

                        case ('nguyen_widrow_weights_ewald')
                            if (lnwweightse /= default_bool) stop err // err_inpnn // 'Multiple use of the nguyen_widrow_weights_ewald key'
                            if (nwords == 1) then
                                lnwweightse = .true.
                            else
                                print *, err, err_inpnn, "nguyen_widrow_weights_ewald key needs no argument(s)"; stop
                            end if

                        case ('print_date_and_time')
                            if (lprintdateandtime /= default_bool) stop err // err_inpnn // 'Multiple use of the print_date_and_time key'
                            if (nwords == 1) then
                                lprintdateandtime = .true.
                            else
                                print *, err, err_inpnn, "print_date_and_time key needs no argument(s)"; stop
                            end if

                        case ('enable_on_the_fly_input')
                            if (lenableontheflyinput /= default_bool) stop err // err_inpnn // 'Multiple use of the enable_on_the_fly_input key'
                            if (nwords == 1) then
                                lenableontheflyinput = .true.
                            else
                                print *, err, err_inpnn, "enable_on_the_fly_input key needs no argument(s)"; stop
                            end if

                        case ('element_decoupled_kalman')
                            if (luseedkalman /= default_bool) stop err // err_inpnn // 'Multiple use of the element_decoupled_kalman key'
                            if (nwords == 1) then
                                luseedkalman = .true.
                            else
                                print *, err, err_inpnn, "element_decoupled_kalman key needs no argument(s)"; stop
                            end if

                        case ('element_decoupled_forces_v2')
                            if (ledforcesv2 /= default_bool) stop err // err_inpnn // 'Multiple use of the element_decoupled_forces_v2 key'
                            if (nwords == 1) then
                                ledforcesv2 = .true.
                            else
                                print *, err, err_inpnn, "element_decoupled_forces_v2 key needs no argument(s)"; stop
                            end if

                        case ('analyze_composition')
                            if (lanalyzecomposition /= default_bool) stop err // err_inpnn // 'Multiple use of the analyze_composition key'
                            if (nwords == 1) then
                                lanalyzecomposition = .true.
                            else
                                print *, err, err_inpnn, "analyze_composition key needs no argument(s)"; stop
                            end if

                        case ('fixed_charge')
                            ! just let it pass

                        case ('print_all_short_weights')
                            ! write(pstring(1:1),'(a1)')'1'
                            ! just let it pass

                        case ('print_all_electrostatic_weights')
                            ! write(pstring(2:2),'(a1)')'1'
                            ! just let it pass

                        case ('print_all_deshortdw')
                            ! write(pstring(3:3),'(a1)')'1'
                            ! just let it pass

                        case ('print_all_dfshortdw')
                            ! write(pstring(4:4),'(a1)')'1'
                            ! just let it pass my precious

                        ! check for keyword which is not related to RuNNer keywords
                        case default
                            if (trim(words(1)) /= '' .and. words(1)(1:1) /= '#') then ! check for empty and comment lines
                                print *, err, err_inpnn, 'The keyword ', trim(words(1)),' in line ', line, ' was not recognized, check the spelling or look at the manual'
                                stop
                            end if

                    end select

                !else
                !    print *, err, err_inpnn, 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

            call inputnndefaults()

            ! end of readout according to readkeywords.f90

            ! further readout according to readinput.f90
            if (lshort .and. (nn_type_short == 1)) then
                do general_counter=1,nelem
                    nodes_short_atomic(maxnum_layers_short_atomic,general_counter)=1
                    if(lelec.and.(nn_type_elec.eq.2))then
                        nodes_short_atomic(maxnum_layers_short_atomic,general_counter) = nodes_short_atomic(maxnum_layers_short_atomic,general_counter)+1
                    endif
                enddo
            endif
            if(lshort.and.(nn_type_short.eq.2))then
                do general_counter=1,npairs
                    nodes_short_pair(maxnum_layers_short_pair,general_counter)=1
                enddo
            endif
            if(lelec.and.(nn_type_elec.eq.1))then
                do general_counter=1,nelem
                    nodes_elec(maxnum_layers_elec,general_counter)=1
                enddo
            endif

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('global_activation_short')
                            if (any(actfunc_short_atomic /= default_string)) stop err // err_inpnn // 'Multiple use of the global_activation_short key'
                            if (nwords == maxnum_layers_short_atomic+1) then
                                do general_counter_1 = 1,maxnum_layers_short_atomic
                                    do general_counter_3 = 1,nelem
                                        do general_counter_2 = 1,nodes_short_atomic
                                            read(words(general_counter_1+1),'(A)', iostat=ios) actfunc_short_atomic_dummy(general_counter_1)
                                            actfunc_short_atomic(general_counter_2, general_counter_1, general_counter_3) = actfunc_short_atomic_dummy(general_counter_1)
                                            !actfunc_short_atomic(general_counter_2, general_counter_1, general_counter_3) = words(general_counter_1+1)
                                        end do
                                        if(nodes_short_atomic(general_counter_1, general_counter_3) .lt. maxnodes_short_atomic)then
                                            do general_counter_2 = nodes_short_atomic(general_counter_1, general_counter_3)+1,maxnodes_short_atomic
                                                actfunc_short_atomic(general_counter_2, general_counter_1, general_counter_3) = ' '
                                            enddo
                                    end do
                                end do
                            else
                                print *, err, err_inpnn, "global_activation_short key needs ", maxnum_layers_short_atomic, " arguments according to maxnum_layers_short_atomic value"; stop
                            end if

                        case ('global_activation_electrostatic')
                            if (any(actfunc_elec /= default_string)) stop err // err_inpnn // 'Multiple use of the global_activation_electrostatic key'
                            if (nwords == maxnum_layers_elec+1) then
                                do general_counter_1 = 1,maxnum_layers_elec
                                    do general_counter_3 = 1,nelem
                                        do general_counter_2 = 1,nodes_elec
                                            read(words(general_counter_1+1),'(A)', iostat=ios) actfunc_elec_dummy(general_counter_1)
                                            actfunc_elec(general_counter_2, general_counter_1, general_counter_3) = actfunc_elec_dummy(general_counter_1)
                                            !actfunc_elec(general_counter_2, general_counter_1, general_counter_3) = words(general_counter_1+1)
                                        end do
                                        if (nodes_elec(general_counter_1, general_counter_3) .lt. maxnodes_elec) then
                                            do general_counter_2 = nodes_elec(general_counter_1, general_counter_3)+1,maxnodes_elec
                                                actfunc_elec(general_counter_2, general_counter_1, general_counter_3) = ' '
                                            enddo
                                    end do
                                end do
                            else
                                print *, err, err_inpnn, "global_activation_electrostatic key needs ", maxnum_layers_elec, " arguments according to maxnum_layers_elec value"; stop
                            end if

                        case ('global_activation_pair')
                            print *, err, err_inpnn, "global_activation_pair key not supported, Pair NN not implemented"; stop

                        case default
                            ! Smeagol shows them secret ways that nobody else could find

                    end select

                !else
                !    write(*,*) err // err_inpnn // 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

            do i=1,nelem
                call nuccharge(element(i),nucelem(i))
            enddo
            call sortelements()

            if(lelec.and.(nn_type_elec.eq.3))then
                call open_for_read(inpnn_unit, filename_inpnn); ios = 0

                do while (ios == 0)
                    read(inpnn_unit, '(A)', iostat=ios) buffer
                    if (ios == 0) then

                        call split_string(buffer, words, nwords)

                        select case (words(1))

                            case ('fixed_charge')
                                !if ((elementtemp /= default_string) .and. (chargetemp /= default_real)) stop err // err_inpnn // 'Multiple use of the fixed_charge key'
                                if (nwords == 3) then
                                    read(words(2),'(A)', iostat=ios) elementtemp
                                    read(words(3),*, iostat=ios) chargetemp
                                    if (ios /= 0) stop err // err_inpnn // "fixed_charge second argument value must be a number"
                                    call nuccharge(elementtemp,ztemp)
                                    fixedcharge(elementindex(ztemp))=chargetemp
                                else
                                    print *, err, err_inpnn, "fixed_charge key needs a single argument"; stop
                                end if

                            case default
                                ! just let it pass

                        end select

                    !else
                    !    write(*,*) err // err_inpnn // 'iostat = ', ios
                    !    stop
                    end if

                end do

                close(inpnn_unit)

                do general_counter_1 = 1,nelem
                    if (fixedcharge(general_counter_1) .gt. 10.0d0) then
                        print *, err, err_inpnn, "Error when reading fixed_charge: No fixed charge specified for element ",element(general_counter_1); stop
                    endif
                enddo
            endif

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('element_hidden_layers_short')
                            !if (elementtemp /= default_string) stop err // err_inpnn // 'Multiple use of the element_hidden_layers_short key'
                            if (nwords == 3) then
                                read(words(2),'(A)', iostat=ios) elementtemp
                                call checkelement(elementtemp)
                                call nuccharge(elementtemp,ztemp)
                                read(words(3),'(i1000)', iostat=ios) num_layers_short_atomic(elementindex(ztemp))
                                if (ios /= 0) stop err // err_inpnn // "element_hidden_layers_short second argument value for element ", ztemp," must be integer"
                                num_layers_short_atomic(elementindex(ztemp)) = num_layers_short_atomic(elementindex(ztemp)) + 1
                                if (num_layers_short_atomic(elementindex(ztemp)) .gt. maxnum_layers_short_atomic) then
                                    print *, err, err_inpnn, "Error when reading element_hidden_layers_short: element ", ztemp, " has too many hidden layers"; stop
                                endif
                                nodes_short_atomic(num_layers_short_atomic(elementindex(ztemp)),elementindex(ztemp)) = 1
                                do general_counter_1=2,maxnodes_short_atomic
                                    actfunc_short_atomic(general_counter_1,num_layers_short_atomic(elementindex(ztemp)),elementindex(ztemp)) = ' '
                                enddo
                            else
                                print *, err, err_inpnn, "element_hidden_layers_short key for element ", ztemp, " needs two arguments"; stop
                            end if

                        case ('element_hidden_layers_electrostatic')
                            !if (elementtemp /= default_string) stop err // err_inpnn // 'Multiple use of the element_hidden_layers_short key'
                            if (nwords == 3) then
                                read(words(2),'(A)', iostat=ios) elementtemp
                                call checkelement(elementtemp)
                                call nuccharge(elementtemp,ztemp)
                                read(words(3),'(i1000)', iostat=ios) num_layers_elec(elementindex(ztemp))
                                if (ios /= 0) stop err // err_inpnn // "element_hidden_layers_electrostatic second argument value for element ", ztemp," must be integer"
                                num_layers_elec(elementindex(ztemp)) = num_layers_elec(elementindex(ztemp)) + 1
                                if (num_layers_elec(elementindex(ztemp)) .gt. maxnum_layers_elec) then
                                    print *, err, err_inpnn, "Error when reading element_hidden_layers_electrostatic: element ", ztemp, " has too many hidden layers"; stop
                                endif
                                nodes_elec(num_layers_elec(elementindex(ztemp)),elementindex(ztemp)) = 1
                                do general_counter_1=2,maxnodes_elec
                                    actfunc_elec(general_counter_1,num_layers_elec(elementindex(ztemp)),elementindex(ztemp)) = ' '
                                enddo
                            else
                                print *, err, err_inpnn, "element_hidden_layers_electrostatic key for element ", ztemp, " needs two arguments"; stop
                            end if

                        case ('element_hidden_layers_pair')
                            print *, err, err_inpnn, "element_hidden_layers_pair key not supported, Pair NN not implemented"; stop

                        case default
                            ! just let it pass

                    end select

                !else
                !    write(*,*) err // err_inpnn // 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('element_nodes_short')
                            if (nwords == 4) then
                                read(words(2),'(A)', iostat=ios) elementtemp
                                call checkelement(elementtemp)
                                call nuccharge(elementtemp,ztemp)
                                read(words(3),'(i1000)', iostat=ios) layer
                                if (ios /= 0) stop err // err_inpnn // "element_nodes_short second argument value for element ", element(elementindex(ztemp)), " must be integer"
                                read(words(4),'(i1000)', iostat=ios) node
                                if (ios /= 0) stop err // err_inpnn // "element_nodes_short third argument value for element ", element(elementindex(ztemp)), " must be integer"
                                if (layer .eq. num_layers_short_atomic(elementindex(ztemp))) then
                                    print *, err, err_inpnn, "Error when reading element_nodes_short: do not modifiy the number of output nodes for element ", element(elementindex(ztemp)); stop
                                endif
                                if (node .gt. maxnodes_short_atomic) then
                                   print *, err, err_inpnn, "Error when reading element_nodes_short: too many nodes requested for element ", element(elementindex(ztemp)); stop
                                end if
                                nodes_short_atomic(layer,elementindex(ztemp)) = node
                                do general_counter_1 = nodes_short_atomic(layer,elementindex(ztemp))+1,maxnodes_short_atomic
                                    actfunc_short_atomic(general_counter_1,layer,elementindex(ztemp)) = ' '
                                end do
                            else
                                print *, err, err_inpnn, "element_nodes_short key for element ", element(elementindex(ztemp)), " needs three arguments"; stop
                            end if

                        case ('element_nodes_electrostatic')
                            if (nwords == 4) then
                                read(words(2),'(A)', iostat=ios) elementtemp
                                call checkelement(elementtemp)
                                call nuccharge(elementtemp,ztemp)
                                read(words(3),'(i1000)', iostat=ios) layer
                                if (ios /= 0) stop err // err_inpnn // "element_nodes_electrostatic second argument value for element ", element(elementindex(ztemp)), " must be integer"
                                read(words(4),'(i1000)', iostat=ios) node
                                if (ios /= 0) stop err // err_inpnn // "element_nodes_electrostatic third argument value for element ", element(elementindex(ztemp)), " must be integer"
                                if (layer .eq. num_layers_elec(elementindex(ztemp))) then
                                    print *, err, err_inpnn, "Error when reading element_nodes_electrostatic: do not modifiy the number of output nodes for element ", element(elementindex(ztemp)); stop
                                endif
                                if (node .gt. maxnodes_elec) then
                                   print *, err, err_inpnn, "Error when reading element_nodes_electrostatic: too many nodes requested for element ", element(elementindex(ztemp)); stop
                                end if
                                nodes_elec(layer,elementindex(ztemp)) = node
                                do general_counter_1 = nodes_elec(layer,elementindex(ztemp))+1,maxnodes_elec
                                    actfunc_elec(general_counter_1,layer,elementindex(ztemp)) = ' '
                                end do
                            else
                                print *, err, err_inpnn, "element_nodes_electrostatic key for element ", element(elementindex(ztemp)), " needs three arguments"; stop
                            end if

                        case ('element_nodes_pair')
                            print *, err, err_inpnn, "element_nodes_pair key not supported, Pair NN not implemented"; stop

                        case default
                            ! just let it pass

                    end select

                !else
                !    print *, err, err_inpnn, 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('element_activation_short')
                            if (nwords == 5) then
                                read(words(2),'(A)', iostat=ios) elementtemp
                                call checkelement(elementtemp)
                                call nuccharge(elementtemp,ztemp)
                                read(words(3),'(i1000)', iostat=ios) layer
                                if (ios /= 0) stop err // err_inpnn // "element_activation_short second argument value for element ", element(elementindex(ztemp)), " must be integer"
                                read(words(4),'(i1000)', iostat=ios) node
                                if (ios /= 0) stop err // err_inpnn // "element_activation_short third argument value for element ", element(elementindex(ztemp)), " must be integer"
                                read(words(5),'(A)', iostat=ios) actfunc
                                if (layer .gt. num_layers_short_atomic(elementindex(ztemp))) then
                                    print *, err, err_inpnn, "Error when reading element_activation_short: layer is too large for element ", element(elementindex(ztemp)); stop
                                endif
                                if (node .gt. nodes_short_atomic(layer,elementindex(ztemp))) then
                                    print *, err, err_inpnn, "Error when reading element_activation_short: node is too large for element ", element(elementindex(ztemp)); stop
                                endif
                                actfunc_short_atomic(node,layer,elementindex(ztemp))=actfunc
                            else
                                print *, err, err_inpnn, "element_activation_short key for element ", element(elementindex(ztemp)), " needs four arguments"; stop
                            end if

                        case ('element_activation_electrostatic')
                            if (nwords == 5) then
                                read(words(2),'(A)', iostat=ios) elementtemp
                                call checkelement(elementtemp)
                                call nuccharge(elementtemp,ztemp)
                                read(words(3),'(i1000)', iostat=ios) layer
                                if (ios /= 0) stop err // err_inpnn // "element_activation_electrostatic second argument value for element ", element(elementindex(ztemp)), " must be integer"
                                read(words(4),'(i1000)', iostat=ios) node
                                if (ios /= 0) stop err // err_inpnn // "element_activation_electrostatic third argument value for element ", element(elementindex(ztemp)), " must be integer"
                                read(words(5),'(A)', iostat=ios) actfunc
                                if (layer .gt. num_layers_elec(elementindex(ztemp))) then
                                    print *, err, err_inpnn, "Error when reading element_activation_electrostatic: layer is too large for element ", element(elementindex(ztemp)); stop
                                endif
                                if (node .gt. nodes_elec(layer,elementindex(ztemp))) then
                                    print *, err, err_inpnn, "Error when reading element_activation_electrostatic: node is too large for element ", element(elementindex(ztemp)); stop
                                endif
                                actfunc_elec(node,layer,elementindex(ztemp))=actfunc
                            else
                                print *, err, err_inpnn, "element_activation_electrostatic key for element ", element(elementindex(ztemp)), " needs four arguments"; stop
                            end if

                        case ('element_activation_pair')
                            print *, err, err_inpnn, "element_activation_pair key not supported, Pair NN not implemented"; stop

                        case default
                            ! just let it pass

                    end select

                !else
                !    print *,  err, err_inpnn, 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

            if (lshort .and. (nn_type_short == 1)) then
                sym_short_atomic_count(:)=0
                num_funcvalues_short_atomic(:)=0
            endif
            if (lelec .and. (nn_type_elec == 1)) then
                sym_elec_count(:)=0
                num_funcvalues_elec(:)=0
            endif

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer
                if (ios == 0) then
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('symfunction_short') ! allocation of arrays is done in allocatesymfunctions() from module symfunctions.f90 when called in initnn.f90! -> no additional allocation subroutine needed!!
                            if (lshort .and. (nn_type_short == 1)) then
                                !call allocate_readsymfunctionatomic(maxnum_funcvalues_short_atomic, sym_short_atomic_count, function_type_short_atomic, symelement_short_atomic, &
                                     !funccutoff_short_atomic, eta_short_atomic, zeta_short_atomic, rshift_short_atomic, lambda_short_atomic) ! maybe there is a better way to set the dimensions of variables needed for the readout?
                                !if (nwords == 5) then
                                read(words(2),'(A)', iostat=ios) elementtemp1
                                call checkelement(elementtemp1)
                                call nuccharge(elementtemp1,ztemp1)
                                sym_short_atomic_count(elementindex(ztemp1)) = sym_short_atomic_count(elementindex(ztemp1)) + 1
                                read(words(3),'(i1000)', iostat=ios) function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                if (ios /= 0) stop err // err_inpnn // "symfunction_short argument 2 value must be integer"

                                select case(words(3))

                                    case ('1')
                                        if (nwords == 5) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 4 must be a number"
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 4 arguments"; stop
                                        end if

                                    case ('2')
                                        if (nwords == 7) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) rshift_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 6 must be a number"
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 6 arguments"; stop
                                        end if

                                    case ('3')
                                        if (nwords == 9) then
                                            read(words(4),'(A)') elementtemp2
                                            read(words(5),'(A)') elementtemp3
                                            call checkelement(elementtemp2)
                                            call checkelement(elementtemp3)
                                            call nuccharge(elementtemp2,ztemp2)
                                            call nuccharge(elementtemp2,ztemp3)
                                            if (ztemp2 .gt. ztemp3) then
                                                itemp = ztemp2
                                                ztemp2 = ztemp3
                                                ztemp3 = itemp
                                            endif
                                            read(words(6),*, iostat=ios) eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) lambda_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 6 must be a number"
                                            read(words(8),*, iostat=ios) zeta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 7 must be a number"
                                            read(words(9),*, iostat=ios) funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 8 must be a number"
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1))=ztemp3
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 8 arguments"; stop
                                        end if

                                    case ('4')
                                        if (nwords == 6) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 5 must be a number"
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 5 arguments"; stop
                                        end if

                                    case ('5')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 3 must be a number"
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('6')
                                        if (nwords == 5) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 4 must be a number"
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 4 arguments"; stop
                                        end if

                                    case ('8')
                                        if (nwords == 8) then
                                            read(words(4),'(A)') elementtemp2
                                            read(words(5),'(A)') elementtemp3
                                            call checkelement(elementtemp2)
                                            call checkelement(elementtemp3)
                                            call nuccharge(elementtemp2,ztemp2)
                                            call nuccharge(elementtemp2,ztemp3)
                                            if (ztemp2 .gt. ztemp3) then
                                                itemp = ztemp2
                                                ztemp2 = ztemp3
                                                ztemp3 = itemp
                                            endif
                                            read(words(6),*, iostat=ios) eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) rshift_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 6 must be a number"
                                            read(words(8),*, iostat=ios) funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 7 must be a number"
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1))=ztemp3
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 7 arguments"; stop
                                        end if

                                    case ('9')
                                        if (nwords == 9) then
                                            read(words(4),'(A)') elementtemp2
                                            read(words(5),'(A)') elementtemp3
                                            call checkelement(elementtemp2)
                                            call checkelement(elementtemp3)
                                            call nuccharge(elementtemp2,ztemp2)
                                            call nuccharge(elementtemp2,ztemp3)
                                            if (ztemp2 .gt. ztemp3) then
                                                itemp = ztemp2
                                                ztemp2 = ztemp3
                                                ztemp3 = itemp
                                            endif
                                            read(words(6),*, iostat=ios) eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) lambda_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 6 must be a number"
                                            read(words(8),*, iostat=ios) zeta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 7 must be a number"
                                            read(words(9),*, iostat=ios) funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_short type ", words(3), " argument 8 must be a number"
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                            symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1))=ztemp3
                                        else
                                            print *, err, err_inpnn, "symfunction_short type ", words(3), " needs 8 arguments"; stop
                                        end if

                                    case default
                                        print *, err, err_inpnn, "Error in symfunction_short key, symfunction type ", words(3), " not implemented"
                                        stop

                                end select

                            end if

                        case ('element_symfunction_short')
                            if (lshort .and. (nn_type_short == 1)) then
                                read(words(2),'(A)', iostat=ios) elementtemp1
                                call checkelement(elementtemp1)
                                call nuccharge(elementtemp1,ztemp1)
                                read(words(3),'(i1000)', iostat=ios) function_type_temp
                                if (ios /= 0) stop err // err_inpnn // "element_symfunction_short argument 2 value must be integer"

                                select case(words(3))

                                    case ('1')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('2')
                                        if (nwords == 6) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 5 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                rshift_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = rshift_temp
                                                funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 5 arguments"; stop
                                        end if

                                    case ('3')
                                        if (nwords == 7) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 6 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                lambda_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                zeta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                            do general_counter_1 = 1,nelem
                                                if (nelem .gt. 1) then
                                                    do general_counter_2 = 1,general_counter_1-1
                                                        sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                        function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                        eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                        lambda_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                        zeta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                        funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                        symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_2)
                                                        symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                    end do
                                                end if
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 6 arguments"; stop
                                        end if

                                    case ('4')
                                        if (nwords == 5) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 4 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 4 arguments"; stop
                                        end if

                                    case ('5')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                            function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                            eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('6')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                            function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('8')
                                        if (nwords == 6) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 5 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                rshift_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = rshift_temp
                                                funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                            do general_counter_1 = 1,nelem
                                                if (nelem .gt. 1) then
                                                    do general_counter_2 = 1,general_counter_1-1
                                                        sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                        function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                        eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                        rshift_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = rshift_temp
                                                        funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                        symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_2)
                                                        symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                    end do
                                                end if
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 5 arguments"; stop
                                        end if

                                    case ('9')
                                        if (nwords == 7) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_short type ", words(3), " argument 6 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                lambda_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                zeta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                            do general_counter_1 = 1,nelem
                                                if (nelem .gt. 1) then
                                                    do general_counter_2 = 1,general_counter_1-1
                                                        sym_short_atomic_count(elementindex(ztemp1) = sym_short_atomic_count(elementindex(ztemp1) + 1
                                                        function_type_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                        eta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                        lambda_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                        zeta_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                        funccutoff_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                        symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_2)
                                                        symelement_short_atomic(sym_short_atomic_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                    end do
                                                end if
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_short type ", words(3), " needs 6 arguments"; stop
                                        end if

                                    case default
                                        print *, err, err_inpnn, "Error in element_symfunction_short key, symfunction type ", words(3), " not implemented"
                                        stop

                                end select

                            end if

                        case ('global_symfunction_short')
                            if (lshort .and. (nn_type_short == 1)) then
                                read(words(2),'(i1000)', iostat=ios) function_type_temp
                                if (ios /= 0) stop err // err_inpnn // "global_symfunction_short argument 1 value must be integer"

                                select case(words(2))

                                    case ('1')
                                        if (nwords == 3) then
                                            read(words(3),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            do general_counter_1 = 1,nelem
                                                do general_counter_2 = 1,nelem
                                                    sym_short_atomic_count(general_counter_1) = sym_short_atomic_count(general_counter_1) + 1
                                                    function_type_short_atomic(sym_short_atomic_count(general_counter_1),general_counter_1) = function_type_temp
                                                    funccutoff_short_atomic(sym_short_atomic_count(general_counter_1),general_counter_1) = funccutoff_temp
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_1),1,general_counter_1) = nucelem(general_counter_2)
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 2 arguments"; stop
                                        end if

                                    case ('2')
                                        if (nwords == 5) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 4 must be a number"
                                            do general_counter_1 = 1,nelem
                                                do general_counter_2 = 1,nelem
                                                    sym_short_atomic_count(general_counter_1) = sym_short_atomic_count(general_counter_1) + 1
                                                    function_type_short_atomic(sym_short_atomic_count(general_counter_1),general_counter_1) = function_type_temp
                                                    eta_short_atomic(sym_short_atomic_count(general_counter_1),general_counter_1) = eta_temp
                                                    rshift_short_atomic(sym_short_atomic_count(general_counter_1),general_counter_1) = rshift_temp
                                                    funccutoff_short_atomic(sym_short_atomic_count(general_counter_1),general_counter_1) = funccutoff_temp
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_1),1,general_counter_1) = nucelem(general_counter_2)
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 4 arguments"; stop
                                        end if

                                    case ('3')
                                        if (nwords == 6) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 5 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                    function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                    lambda_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = lambda_temp
                                                    zeta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = zeta_temp
                                                    funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                                do general_counter_1 = 1,nelem
                                                    if (nelem .gt. 1) then
                                                        do general_counter_2 = 1,general_counter_1-1
                                                            sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                            function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                            eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                            lambda_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = lambda_temp
                                                            zeta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = zeta_temp
                                                            funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                            symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_2)
                                                            symelement_short_atomic(sym_short_atomic_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                        end do
                                                    end if
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 5 arguments"; stop
                                        end if

                                    case ('4')
                                        if (nwords == 4) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 3 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                    function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                    funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 3 arguments"; stop
                                        end if

                                    case ('5')
                                        if (nwords == 3) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            do general_counter_3 = 1,nelem
                                                sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_3)
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 2 arguments"; stop
                                        end if

                                    case ('6')
                                        if (nwords == 3) then
                                            read(words(3),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            do general_counter_3 = 1,nelem
                                                sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_3)
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 2 arguments"; stop
                                        end if

                                    case ('8')
                                        if (nwords == 5) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 4 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                    function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                    rshift_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = rshift_temp
                                                    funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                                do general_counter_1 = 1,nelem
                                                    if (nelem .gt. 1) then
                                                        do general_counter_2 = 1,general_counter_1-1
                                                            sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                            function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                            eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                            rshift_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = rshift_temp
                                                            funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                            symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_2)
                                                            symelement_short_atomic(sym_short_atomic_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                        end do
                                                    end if
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 4 arguments"; stop
                                        end if

                                    case ('9')
                                        if (nwords == 6) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_short type ", words(2), " argument 5 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                    function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                    lambda_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = lambda_temp
                                                    zeta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = zeta_temp
                                                    funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                    symelement_short_atomic(sym_short_atomic_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                                do general_counter_1 = 1,nelem
                                                    if (nelem .gt. 1) then
                                                        do general_counter_2 = 1,general_counter_1-1
                                                            sym_short_atomic_count(general_counter_3) = sym_short_atomic_count(general_counter_3) + 1
                                                            function_type_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = function_type_temp
                                                            eta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = eta_temp
                                                            lambda_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = lambda_temp
                                                            zeta_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = zeta_temp
                                                            funccutoff_short_atomic(sym_short_atomic_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                            symelement_short_atomic(sym_short_atomic_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_2)
                                                            symelement_short_atomic(sym_short_atomic_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                        end do
                                                    end if
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_short type ", words(2), " needs 5 arguments"; stop
                                        end if

                                    case default
                                        print *, err, err_inpnn, "Error in global_symfunction_short key, symfunction type ", words(2), " not implemented"
                                        stop

                                end select

                            end if


                        case ('symfunction_electrostatic')
                            if (lelec .and. (nn_type_elec == 1)) then
                                read(words(2),'(A)', iostat=ios) elementtemp1
                                call checkelement(elementtemp1)
                                call nuccharge(elementtemp1,ztemp1)
                                sym_elec_count(elementindex(ztemp1)) = sym_elec_count(elementindex(ztemp1)) + 1
                                read(words(3),'(i1000)', iostat=ios) function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic argument 2 value must be integer"

                                select case(words(3))

                                    case ('1')
                                        if (nwords == 5) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 4 arguments"; stop
                                        end if

                                    case ('2')
                                        if (nwords == 7) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) rshift_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 6 must be a number"
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 6 arguments"; stop
                                        end if

                                    case ('3')
                                        if (nwords == 9) then
                                            read(words(4),'(A)') elementtemp2
                                            read(words(5),'(A)') elementtemp3
                                            call checkelement(elementtemp2)
                                            call checkelement(elementtemp3)
                                            call nuccharge(elementtemp2,ztemp2)
                                            call nuccharge(elementtemp2,ztemp3)
                                            if (ztemp2 .gt. ztemp3) then
                                                itemp = ztemp2
                                                ztemp2 = ztemp3
                                                ztemp3 = itemp
                                            endif
                                            read(words(6),*, iostat=ios) eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) lambda_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 6 must be a number"
                                            read(words(8),*, iostat=ios) zeta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 7 must be a number"
                                            read(words(9),*, iostat=ios) funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 8 must be a number"
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1))=ztemp3
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 8 arguments"; stop
                                        end if

                                    case ('4')
                                        if (nwords == 6) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_elecc(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 5 arguments"; stop
                                        end if

                                    case ('5')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('6')
                                        if (nwords == 5) then
                                            read(words(4),'(A)') elementtemp2
                                            call checkelement(elementtemp2)
                                            call nuccharge(elementtemp2,ztemp2)
                                            read(words(5),*, iostat=ios) funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 4 arguments"; stop
                                        end if

                                    case ('8')
                                        if (nwords == 8) then
                                            read(words(4),'(A)') elementtemp2
                                            read(words(5),'(A)') elementtemp3
                                            call checkelement(elementtemp2)
                                            call checkelement(elementtemp3)
                                            call nuccharge(elementtemp2,ztemp2)
                                            call nuccharge(elementtemp2,ztemp3)
                                            if (ztemp2 .gt. ztemp3) then
                                                itemp = ztemp2
                                                ztemp2 = ztemp3
                                                ztemp3 = itemp
                                            endif
                                            read(words(6),*, iostat=ios) eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) rshift_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 6 must be a number"
                                            read(words(8),*, iostat=ios) funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 7 must be a number"
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1))=ztemp3
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 7 arguments"; stop
                                        end if

                                    case ('9')
                                        if (nwords == 9) then
                                            read(words(4),'(A)') elementtemp2
                                            read(words(5),'(A)') elementtemp3
                                            call checkelement(elementtemp2)
                                            call checkelement(elementtemp3)
                                            call nuccharge(elementtemp2,ztemp2)
                                            call nuccharge(elementtemp2,ztemp3)
                                            if (ztemp2 .gt. ztemp3) then
                                                itemp = ztemp2
                                                ztemp2 = ztemp3
                                                ztemp3 = itemp
                                            endif
                                            read(words(6),*, iostat=ios) eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) lambda_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 6 must be a number"
                                            read(words(8),*, iostat=ios) zeta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 7 must be a number"
                                            read(words(9),*, iostat=ios) funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1))
                                            if (ios /= 0) stop err // err_inpnn // "symfunction_electrostatic type ", words(3), " argument 8 must be a number"
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1))=ztemp2
                                            symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1))=ztemp3
                                        else
                                            print *, err, err_inpnn, "symfunction_electrostatic type ", words(3), " needs 8 arguments"; stop
                                        end if

                                    case default
                                        print *, err, err_inpnn, "Error in symfunction_electrostatict key, symfunction type ", words(3), " not implemented"
                                        stop

                                end select

                            end if

                        case ('element_symfunction_electrostatic')
                            if (lelec .and. (nn_type_elec == 1)) then
                                read(words(2),'(A)', iostat=ios) elementtemp1
                                call checkelement(elementtemp1)
                                call nuccharge(elementtemp1,ztemp1)
                                read(words(3),'(i1000)', iostat=ios) function_type_temp
                                if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic argument 2 value must be integer"

                                select case(words(3))

                                    case ('1')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('2')
                                        if (nwords == 6) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                rshift_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = rshift_temp
                                                funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 5 arguments"; stop
                                        end if

                                    case ('3')
                                        if (nwords == 7) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 6 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                lambda_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                zeta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                            do general_counter_1 = 1,nelem
                                                if (nelem .gt. 1) then
                                                    do general_counter_2 = 1,general_counter_1-1
                                                        sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                        function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                        eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                        lambda_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                        zeta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                        funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                        symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_2)
                                                        symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                    end do
                                                end if
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 6 arguments"; stop
                                        end if

                                    case ('4')
                                        if (nwords == 5) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 4 arguments"; stop
                                        end if

                                    case ('5')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                            function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                            eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('6')
                                        if (nwords == 4) then
                                            read(words(4),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                            function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 3 arguments"; stop
                                        end if

                                    case ('8')
                                        if (nwords == 6) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                rshift_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = rshift_temp
                                                funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                            do general_counter_1 = 1,nelem
                                                if (nelem .gt. 1) then
                                                    do general_counter_2 = 1,general_counter_1-1
                                                        sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                        function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                        eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                        rshift_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = rshift_temp
                                                        funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                        symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_2)
                                                        symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                    end do
                                                end if
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 5 arguments"; stop
                                        end if

                                    case ('9')
                                        if (nwords == 7) then
                                            read(words(4),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 5 must be a number"
                                            read(words(7),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "element_symfunction_electrostatic type ", words(3), " argument 6 must be a number"
                                            do general_counter_1 = 1,nelem
                                                sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                lambda_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                zeta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_1)
                                            end do
                                            do general_counter_1 = 1,nelem
                                                if (nelem .gt. 1) then
                                                    do general_counter_2 = 1,general_counter_1-1
                                                        sym_elec_count(elementindex(ztemp1) = sym_elec_count(elementindex(ztemp1) + 1
                                                        function_type_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = function_type_temp
                                                        eta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = eta_temp
                                                        lambda_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = lambda_temp
                                                        zeta_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = zeta_temp
                                                        funccutoff_elec(sym_elec_count(elementindex(ztemp1)),elementindex(ztemp1)) = funccutoff_temp
                                                        symelement_elec(sym_elec_count(elementindex(ztemp1)),1,elementindex(ztemp1)) = nucelem(general_counter_2)
                                                        symelement_elec(sym_elec_count(elementindex(ztemp1)),2,elementindex(ztemp1)) = nucelem(general_counter_1)
                                                    end do
                                                end if
                                            end do
                                        else
                                            print *, err, err_inpnn, "element_symfunction_electrostatic type ", words(3), " needs 6 arguments"; stop
                                        end if

                                    case default
                                        print *, err, err_inpnn, "Error in element_symfunction_electrostatic key, symfunction type ", words(3), " not implemented"
                                        stop

                                end select

                            end if

                        case ('global_symfunction_electrostatic')
                            if (lelec .and. (nn_type_elec == 1)) then
                                read(words(2),'(i1000)', iostat=ios) function_type_temp
                                if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic argument 1 value must be integer"

                                select case(words(2))

                                    case ('1')
                                        if (nwords == 3) then
                                            read(words(3),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            do general_counter_1 = 1,nelem
                                                do general_counter_2 = 1,nelem
                                                    sym_elec_count(general_counter_1) = sym_elec_count(general_counter_1) + 1
                                                    function_type_elec(sym_elec_count(general_counter_1),general_counter_1) = function_type_temp
                                                    funccutoff_elec(sym_elec_count(general_counter_1),general_counter_1) = funccutoff_temp
                                                    symelement_elec(sym_elec_count(general_counter_1),1,general_counter_1) = nucelem(general_counter_2)
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 2 arguments"; stop
                                        end if

                                    case ('2')
                                        if (nwords == 5) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 4 must be a number"
                                            do general_counter_1 = 1,nelem
                                                do general_counter_2 = 1,nelem
                                                    sym_elec_count(general_counter_1) = sym_elec_count(general_counter_1) + 1
                                                    function_type_elec(sym_elec_count(general_counter_1),general_counter_1) = function_type_temp
                                                    eta_elec(sym_elec_count(general_counter_1),general_counter_1) = eta_temp
                                                    rshift_elec(sym_elec_count(general_counter_1),general_counter_1) = rshift_temp
                                                    funccutoff_elec(sym_elec_count(general_counter_1),general_counter_1) = funccutoff_temp
                                                    symelement_elec(sym_elec_count(general_counter_1),1,general_counter_1) = nucelem(general_counter_2)
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 4 arguments"; stop
                                        end if

                                    case ('3')
                                        if (nwords == 6) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 5 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                    function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                    lambda_elec(sym_elec_count(general_counter_3),general_counter_3) = lambda_temp
                                                    zeta_elec(sym_elec_count(general_counter_3),general_counter_3) = zeta_temp
                                                    funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                    symelement_elec(sym_elec_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                                do general_counter_1 = 1,nelem
                                                    if (nelem .gt. 1) then
                                                        do general_counter_2 = 1,general_counter_1-1
                                                            sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                            function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                            eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                            lambda_elec(sym_elec_count(general_counter_3),general_counter_3) = lambda_temp
                                                            zeta_elec(sym_elec_count(general_counter_3),general_counter_3) = zeta_temp
                                                            funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                            symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_2)
                                                            symelement_elec(sym_elec_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                        end do
                                                    end if
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 5 arguments"; stop
                                        end if

                                    case ('4')
                                        if (nwords == 4) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 3 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                    function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                    funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 3 arguments"; stop
                                        end if

                                    case ('5')
                                        if (nwords == 3) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            do general_counter_3 = 1,nelem
                                                sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_3)
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 2 arguments"; stop
                                        end if

                                    case ('6')
                                        if (nwords == 3) then
                                            read(words(3),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            do general_counter_3 = 1,nelem
                                                sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_3)
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 2 arguments"; stop
                                        end if

                                    case ('8')
                                        if (nwords == 5) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) rshift_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 4 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                    function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                    rshift_elec(sym_elec_count(general_counter_3),general_counter_3) = rshift_temp
                                                    funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                    symelement_elec(sym_elec_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                                do general_counter_1 = 1,nelem
                                                    if (nelem .gt. 1) then
                                                        do general_counter_2 = 1,general_counter_1-1
                                                            sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                            function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                            eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                            rshift_elec(sym_elec_count(general_counter_3),general_counter_3) = rshift_temp
                                                            funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                            symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_2)
                                                            symelement_elec(sym_elec_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                        end do
                                                    end if
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 4 arguments"; stop
                                        end if

                                    case ('9')
                                        if (nwords == 6) then
                                            read(words(3),*, iostat=ios) eta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 2 must be a number"
                                            read(words(4),*, iostat=ios) lambda_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 3 must be a number"
                                            read(words(5),*, iostat=ios) zeta_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 4 must be a number"
                                            read(words(6),*, iostat=ios) funccutoff_temp
                                            if (ios /= 0) stop err // err_inpnn // "global_symfunction_electrostatic type ", words(2), " argument 5 must be a number"
                                            do general_counter_3 = 1,nelem
                                                do general_counter_1 = 1,nelem
                                                    sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                    function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                    eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                    lambda_elec(sym_elec_count(general_counter_3),general_counter_3) = lambda_temp
                                                    zeta_elec(sym_elec_count(general_counter_3),general_counter_3) = zeta_temp
                                                    funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                    symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_1)
                                                    symelement_elec(sym_elec_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                end do
                                                do general_counter_1 = 1,nelem
                                                    if (nelem .gt. 1) then
                                                        do general_counter_2 = 1,general_counter_1-1
                                                            sym_elec_count(general_counter_3) = sym_elec_count(general_counter_3) + 1
                                                            function_type_elec(sym_elec_count(general_counter_3),general_counter_3) = function_type_temp
                                                            eta_elec(sym_elec_count(general_counter_3),general_counter_3) = eta_temp
                                                            lambda_elec(sym_elec_count(general_counter_3),general_counter_3) = lambda_temp
                                                            zeta_elec(sym_elec_count(general_counter_3),general_counter_3) = zeta_temp
                                                            funccutoff_elec(sym_elec_count(general_counter_3),general_counter_3) = funccutoff_temp
                                                            symelement_elec(sym_elec_count(general_counter_3),1,general_counter_3) = nucelem(general_counter_2)
                                                            symelement_elec(sym_elec_count(general_counter_3),2,general_counter_3) = nucelem(general_counter_1)
                                                        end do
                                                    end if
                                                end do
                                            end do
                                        else
                                            print *, err, err_inpnn, "global_symfunction_electrostatic type ", words(2), " needs 5 arguments"; stop
                                        end if

                                    case default
                                        print *, err, err_inpnn, "Error in global_symfunction_electrostatic key, symfunction type ", words(2), " not implemented"
                                        stop

                                end select

                            end if

                        case ('global_pairsymfunction_short')
                            print *, err, err_inpnn, "global_pairsymfunction_short key not supported, Pair NN not implemented"; stop

                        case ('element_pairsymfunction_short')
                            print *, err, err_inpnn, "element_pairsymfunction_short key not supported, Pair NN not implemented"; stop

                        case ('pairsymfunction_short')
                            print *, err, err_inpnn, "pairsymfunction_short key not supported, Pair NN not implemented"; stop

                        case default
                            ! just let it pass

                    end select

                !else
                !    print *, err, err_inpnn, 'iostat = ', ios
                !    stop
                end if

            end do

            close(inpnn_unit)

            do i1=1,nelem
                if(lshort.and.(nn_type_short.eq.1))then
                    num_funcvalues_short_atomic(i1)=sym_short_atomic_count(i1)
                    nodes_short_atomic(0,i1)=num_funcvalues_short_atomic(i1)
                endif
                if(lelec.and.(nn_type_elec.eq.1))then
                    num_funcvalues_elec(i1)=sym_elec_count(i1)
                    nodes_elec(0,i1)=num_funcvalues_elec(i1)
                endif
            enddo

            if(lshort.and.(nn_type_short.eq.1))then
                do i1=1,nelem
                    if(num_funcvalues_short_atomic(i1).eq.0)then
                        print *, 'ERROR: No short range symfunctions specified for ',element(i1)
                        stop
                    endif
                enddo
            endif
            if(lelec.and.(nn_type_elec.eq.1))then
                do i1=1,nelem
                    if(num_funcvalues_elec(i1).eq.0)then
                        print *, 'ERROR: No electrostatic symfunctions specified for ',element(i1)
                        stop
                    endif
                enddo
            endif

            ! call set_runner_counters() ! to avoid unwanted error messages in checkinputnn() subroutine

            call checkinputnn(err, err_inpnn) ! own subroutine in pes_nene_mod_supply.f90

            call printinputnn(iseed,ielem,nodes_short_atomic_temp,nodes_elec_temp,nodes_short_pair_temp,kalmanlambda_local,kalmanlambdae_local,actfunc_short_atomic_dummy,actfunc_elec_dummy,actfunc_short_pair_dummy)

            write(*,'(a15,i4,a30)')' Element pairs: ',npairs,' , shortest distance (Bohr)'
            icount=0
            do i=1,nelem
                do j=i,nelem
                    icount=icount+1
                    if(dmin_element(icount).lt.9999.d0)then
                        write(*,'(a6,i4,2a3,1x,f10.3)')' pair ',&
                        icount,element(i),element(j),dmin_element(icount)
                    endif
                enddo
            enddo
            print *, '============================================================='

            if(lshort.and.(nn_type_short.eq.1))then
                do i1=1,nelem
                    wcount=0
                    do i=1,num_layers_short_atomic(i1)
                        wcount=wcount+1
                        windex_short_atomic(wcount,i1)=num_weights_short_atomic(i1)+1
                        num_weights_short_atomic(i1)=num_weights_short_atomic(i1)&
                          +nodes_short_atomic(i-1,i1)*nodes_short_atomic(i,i1)
                        wcount=wcount+1
                        windex_short_atomic(wcount,i1)=num_weights_short_atomic(i1)+1
                        num_weights_short_atomic(i1)=num_weights_short_atomic(i1)&
                          +nodes_short_atomic(i,i1) ! bias weights
                    enddo
                    if((mode.eq.2).or.(mode.eq.3))then
                        write(*,'(a,a3,i10)')' => short range NN weights type 1                ',&
                        element(i1),num_weights_short_atomic(i1)
                    endif
                    maxnum_weights_short_atomic=max(maxnum_weights_short_atomic,num_weights_short_atomic(i1))
                enddo
            endif

            if(lelec.and.(nn_type_elec.eq.1))then
                do i1=1,nelem
                    wcount=0
                    do i=1,num_layers_elec(i1)
                        wcount=wcount+1
                        windex_elec(wcount,i1)=num_weights_elec(i1)+1
                        num_weights_elec(i1)=num_weights_elec(i1)+nodes_elec(i-1,i1)*nodes_elec(i,i1)
                        wcount=wcount+1
                        windex_elec(wcount,i1)=num_weights_elec(i1)+1
                        num_weights_elec(i1)=num_weights_elec(i1)+nodes_elec(i,i1)
                    enddo
                    write(*,'(a,a3,i10)')' => electrostatic NN weights                     ',element(i1),num_weights_elec(i1)
                    maxnum_weights_elec=max(maxnum_weights_elec,num_weights_elec(i1))
                enddo
            endif
            write(*,*)'-------------------------------------------------------------'

            if(nn_type_short.eq.1)then
                maxnum_weights_short_pair=1
            endif
            if((.not.lelec).or.(lelec.and.(nn_type_elec.ne.1)))then
                maxnum_weights_elec=1
            endif

            if(lremoveatomenergies)then
                !call readatomenergies()

                ! start readout of input.nn according to readatomenergies.f90
                call open_for_read(inpnn_unit, filename_inpnn); ios = 0

                do while (ios == 0)
                    read(inpnn_unit, '(A)', iostat=ios) buffer

                    if (ios == 0) then
                        line = line + 1
                        call split_string(buffer, words, nwords)
                        atom_energy_counter = 0

                        select case (words(1))

                            case ('atom_energy')
                                !if ( /= default_int) stop err // err_inpnn // 'Multiple use of the  key'
                                if (nwords == 3) then
                                    read(words(2),'(A)', iostat=ios) elementtemp
                                    call nuccharge(elementtemp,ztemp)
                                    do general_counter_1 = 1,nelem
                                        if (ztemp.eq.nucelem(general_counter_1)) then
                                            atom_energy_counter = atom_energy_counter + 1
                                            read(words(2),'(A)', iostat=ios) elementtemp(atom_energy_counter)
                                            read(words(3),*, iostat=ios) atomrefenergies(atom_energy_counter)
                                            if (ios /= 0) stop err // err_inpnn // "atom_energy key in line ", line, " second argument value must be a number"
                                        else
                                            print *, warn_inpnn, 'atom_energy for element ',elementtemp,' is ignored'
                                        end if
                                    end do
                                else
                                    print *, err, err_inpnn, "atom_energy key in line ", line, " needs 2 arguments"; stop
                                end if

                            case default
                                ! just let it pass

                        end select

                    !else
                    !    print *, err, err_inpnn, 'iostat = ', ios
                    !    stop
                    end if

                end do

                close(inpnn_unit)

                do general_counter_1 = 1,atom_energy_counter
                    call nuccharge(elementsymbol(atom_energy_counter),zelem(atom_energy_counter))
                end do

                if(nelem.gt.1)then
                    do atom_energy_counter = 1,nelem-1
                        if (zelem(atom_energy_counter) .gt. zelem(atom_energy_counter+1)) then
                            ztemp=zelem(atom_energy_counter)
                            elementtemp=elementsymbol(atom_energy_counter)
                            etemp=atomrefenergies(atom_energy_counter)
                            zelem(atom_energy_counter)=zelem(atom_energy_counter+1)
                            elementsymbol(atom_energy_counter)=elementsymbol(atom_energy_counter+1)
                            atomrefenergies(atom_energy_counter)=atomrefenergies(atom_energy_counter+1)
                            zelem(atom_energy_counter+1)=ztemp
                            elementsymbol(atom_energy_counter+1)=elementtemp
                            atomrefenergies(atom_energy_counter+1)=etemp
                        endif
                    enddo
                endif

                lfound(:)=.false.
                do atom_energy_counter=1,nelem
                    lfound(elementindex(zelem(atom_energy_counter)))=.true.
                enddo

                do atom_energy_counter=1,nelem
                    if (lfound(atom_energy_counter) .eqv. .false.) then
                        print *, err, err_inpnn, 'Error: atom_energy not found for element ', nucelem(atom_energy_counter)
                        stop
                    endif
                enddo

                print *, 'atomic reference energies read from input.nn:'

                do atom_energy_counter=1,nelem
                    write(*,'(a1,a2,x,f18.8)')' ',elementsymbol(atom_energy_counter),atomrefenergies(atom_energy_counter)
                enddo
                ! end readout of input.nn according to readatomenergies.f90

            endif

            call open_for_read(inpnn_unit, filename_inpnn); ios = 0

            do while (ios == 0)
                read(inpnn_unit, '(A)', iostat=ios) buffer

                if (ios == 0) then
                    call split_string(buffer, words, nwords)

                    select case (words(1))

                        case ('node_activation_short')
                            !if ( lnode_activation_short /= default_bool) stop err // err_inpnn // 'Multiple use of the node_activation_short key'
                            !lnode_activation_short = .true.
                            print *, err, err_inpnn, "node_activation_short key was found, read activation functions of individual nodes is not implemented"; stop

                        case default
                            ! just let it pass

                    end select

                end if

            end do

            close(inpnn_unit)

            if(lshort.and.(nn_type_short.eq.1).and.(mode.ne.1))then
                do i3=1,nelem
                    write(*,*)'-------------------------------------------------'
                    write(*,*)'Atomic short range NN for element: ',element(i3)
                    write(*,'(a,10i5)')' architecture    ',(nodes_short_atomic(i1,i3),i1=0,num_layers_short_atomic(i3))
                    write(*,*)'-------------------------------------------------'
                    itemp=0
                    do i1=0,num_layers_short_atomic(i3)
                        itemp=max(itemp,nodes_short_atomic(i1,i3))
                    enddo ! i1
                    do i1=1,itemp ! loop over all lines with hidden nodes
                        if(i1.le.nodes_short_atomic(0,i3))then ! still input node to be printed
                            if(i1.le.maxnodes_short_atomic)then ! still hidden nodes present
                                write(*,'(i4,x,9a3)')i1,'  G',(actfunc_short_atomic(i1,i2,i3),i2=1,num_layers_short_atomic(i3))
                            else
                                write(*,'(i4,x,a3)')i1,'  G'
                            endif
                        else ! no input node in front of hidden nodes
                            write(*,'(i4,4x,8a3)')i1,(actfunc_short_atomic(i1,i2,i3),i2=1,num_layers_short_atomic(i3))
                        endif
                    enddo
                enddo ! i3
            endif

            if(lelec.and.(nn_type_elec.eq.1).and.(mode.ne.1))then
                do i3=1,nelem
                    write(*,*)'---------------------------------------------------'
                    write(*,*)'Electrostatic NN for element: ',element(i3)
                    write(*,'(a,10i5)')' architecture    ',(nodes_elec(i1,i3),i1=0,num_layers_elec(i3))
                    write(*,*)'---------------------------------------------------'
                    itemp=0
                    do i1=0,num_layers_elec(i3)
                        itemp=max(itemp,nodes_elec(i1,i3))
                    enddo ! i1
                    do i1=1,itemp ! loop over all lines with hidden nodes
                        if(i1.le.nodes_elec(0,i3))then ! still input node to be printed
                            if(i1.le.maxnodes_elec)then ! still hidden nodes present
                                write(*,'(i4,x,9a3)')i1,'  G',(actfunc_elec(i1,i2,i3),i2=1,num_layers_elec(i3))
                            else
                                write(*,'(i4,x,a3)')i1,'  G'
                            endif
                        else ! no input node in front of hidden nodes
                            write(*,'(i4,4x,8a3)')i1,(actfunc_elec(i1,i2,i3),i2=1,num_layers_elec(i3))
                        endif
                    enddo
                enddo ! i3
            endif
            write(*,*)'-------------------------------------------------------------'

            if((nn_type_short.eq.1).and.lshort)then
                call sortsymfunctions(&
                  maxnum_funcvalues_short_atomic,num_funcvalues_short_atomic,function_type_short_atomic,symelement_short_atomic,eta_short_atomic,zeta_short_atomic,rshift_short_atomic,lambda_short_atomic,funccutoff_short_atomic)
            endif

            if(lelec.and.(nn_type_elec.eq.1))then
                call sortsymfunctions(&
                  maxnum_funcvalues_elec,num_funcvalues_elec,function_type_elec,symelement_elec,eta_elec,zeta_elec,rshift_elec,lambda_elec,funccutoff_elec)
            endif

            if(lshort.and.(nn_type_short.eq.1))then
        do i1=1,nelem
          write(*,*)'-------------------------------------------------------------'
          write(*,*)' short range atomic symmetry &
                          &functions element ',element(i1),' :'
          write(*,*)'-------------------------------------------------------------'
          do i2=1,num_funcvalues_short_atomic(i1)
            if(function_type_short_atomic(i2,i1).eq.1)then
              write(*,'(i5,a3,i3,x,a3,3x,24x,f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),&
                element(elementindex(symelement_short_atomic(i2,1,i1))),&
                funccutoff_short_atomic(i2,i1)
            elseif(function_type_short_atomic(i2,i1).eq.2)then
              write(*,'(i5,a3,i3,x,a3,3x,8x,3f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),&
                element(elementindex(symelement_short_atomic(i2,1,i1))),&
                eta_short_atomic(i2,i1),rshift_short_atomic(i2,i1),funccutoff_short_atomic(i2,i1)
            elseif(function_type_short_atomic(i2,i1).eq.3)then
              write(*,'(i5,a3,i3,x,2a3,4f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),&
                element(elementindex(symelement_short_atomic(i2,1,i1))),&
                element(elementindex(symelement_short_atomic(i2,2,i1))),&
                eta_short_atomic(i2,i1),lambda_short_atomic(i2,i1),&
                zeta_short_atomic(i2,i1),funccutoff_short_atomic(i2,i1)
            elseif(function_type_short_atomic(i2,i1).eq.4)then
              write(*,'(i5,a3,i3,x,a3,3x,16x,2f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),&
                element(elementindex(symelement_short_atomic(i2,1,i1))),&
                eta_short_atomic(i2,i1),funccutoff_short_atomic(i2,i1)
            elseif(function_type_short_atomic(i2,i1).eq.5)then
              write(*,'(i5,a3,i3,4x,27x,f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),eta_short_atomic(i2,i1)
            elseif(function_type_short_atomic(i2,i1).eq.6)then
              write(*,'(i5,a3,i3,x,a3,3x,24x,f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),&
                element(elementindex(symelement_short_atomic(i2,1,i1))),&
                funccutoff_short_atomic(i2,i1)
            elseif(function_type_short_atomic(i2,i1).eq.8)then
              write(*,'(i5,a3,i3,x,2a3,4f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),&
                element(elementindex(symelement_short_atomic(i2,1,i1))),&
                element(elementindex(symelement_short_atomic(i2,2,i1))),&
                eta_short_atomic(i2,i1),rshift_short_atomic(i2,i1),&
                funccutoff_short_atomic(i2,i1)
            elseif(function_type_short_atomic(i2,i1).eq.9)then
              write(*,'(i5,a3,i3,x,2a3,4f8.3)')&
                i2,element(i1),function_type_short_atomic(i2,i1),&
                element(elementindex(symelement_short_atomic(i2,1,i1))),&
                element(elementindex(symelement_short_atomic(i2,2,i1))),&
                eta_short_atomic(i2,i1),lambda_short_atomic(i2,i1),&
                zeta_short_atomic(i2,i1),funccutoff_short_atomic(i2,i1)
            else
              write(*,*)'Error: printing unknown symfunction in readinput '
              stop
            endif
          enddo ! i2
        enddo ! i1=1,nelem
      endif ! lshort

          if(lelec.and.(nn_type_elec.eq.1))then
        do i1=1,nelem
          write(*,*)'-------------------------------------------------------------'
          write(*,*)' electrostatic symmetry functions element ',element(i1),' :'
          write(*,*)'-------------------------------------------------------------'
          do i2=1,num_funcvalues_elec(i1)
            if(function_type_elec(i2,i1).eq.1)then
              write(*,'(i5,a3,i3,x,a3,3x,24x,f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),&
                element(elementindex(symelement_elec(i2,1,i1))),&
                funccutoff_elec(i2,i1)
            elseif(function_type_elec(i2,i1).eq.2)then
              write(*,'(i5,a3,i3,x,a3,3x,8x,3f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),&
                element(elementindex(symelement_elec(i2,1,i1))),&
                eta_elec(i2,i1),rshift_elec(i2,i1),funccutoff_elec(i2,i1)
            elseif(function_type_elec(i2,i1).eq.3)then
              write(*,'(i5,a3,i3,x,2a3,4f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),&
                element(elementindex(symelement_elec(i2,1,i1))),&
                element(elementindex(symelement_elec(i2,2,i1))),&
                eta_elec(i2,i1),lambda_elec(i2,i1),&
                zeta_elec(i2,i1),funccutoff_elec(i2,i1)
            elseif(function_type_elec(i2,i1).eq.4)then
              write(*,'(i5,a3,i3,x,a3,3x,16x,2f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),&
                element(elementindex(symelement_elec(i2,1,i1))),&
                eta_elec(i2,i1),funccutoff_elec(i2,i1)
            elseif(function_type_elec(i2,i1).eq.5)then
              write(*,'(i5,a3,i3,4x,27x,f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),eta_elec(i2,i1)
            elseif(function_type_elec(i2,i1).eq.6)then
              write(*,'(i5,a3,i3,x,a3,3x,24x,f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),&
                element(elementindex(symelement_elec(i2,1,i1))),&
                funccutoff_elec(i2,i1)
            elseif(function_type_elec(i2,i1).eq.8)then
              write(*,'(i5,a3,i3,x,2a3,4f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),&
                element(elementindex(symelement_elec(i2,1,i1))),&
                element(elementindex(symelement_elec(i2,2,i1))),&
                eta_elec(i2,i1),rshift_elec(i2,i1),&
                funccutoff_elec(i2,i1)
            elseif(function_type_elec(i2,i1).eq.9)then
              write(*,'(i5,a3,i3,x,2a3,4f8.3)')&
                i2,element(i1),function_type_elec(i2,i1),&
                element(elementindex(symelement_elec(i2,1,i1))),&
                element(elementindex(symelement_elec(i2,2,i1))),&
                eta_elec(i2,i1),lambda_elec(i2,i1),&
                zeta_elec(i2,i1),funccutoff_elec(i2,i1)
            else
              write(*,*)'Error: printing unknown symfunctione in readinput '
              stop
            endif
          enddo ! i2
        enddo ! i1=1,nelem
      endif ! lelec
      write(*,*)'-------------------------------------------------------------'
      ! end of readout according to readinput.f90








        ! further readout according to initnn.f90
        call getlistdim()

        !call distribute_predictionoptions() ! only mpi dummy routines

        !call distribute_symfunctions() ! in symfunctions.f90, only mpi dummy routines

        !call distribute_globaloptions() ! only mpi dummy routines

        if (lshort .and. (nn_type_short.eq.1)) then
            allocate (weights_short_atomic(maxnum_weights_short_atomic,nelem))
            weights_short_atomic(:,:)=0.0d0
            allocate (symfunction_short_atomic_list(maxnum_funcvalues_short_atomic,max_num_atoms,nblock))
            symfunction_short_atomic_list(:,:,:)=0.0d0
        end if

        if(lelec.and.(nn_type_elec.eq.1))then
            allocate (weights_elec(maxnum_weights_elec,nelem))
            weights_elec(:,:)=0.0d0
            allocate (symfunction_elec_list(maxnum_funcvalues_elec,max_num_atoms,nblock))
            symfunction_elec_list(:,:,:)=0.0d0
        end if
        ! end of readout according to initnn.f90, all things have been read and set up, ready for compute_nene()!!


        ! read in biases and weights for short part
        if(lshort.and.(nn_type_short.eq.1))then
            ! check existance of scaling.data
            if (.not. file_exists(filename_scaling)) stop err // err_scaling // 'file does not exist'
            ! read in all data from scaling.data
            call readscale(filename_scaling,err_scaling,nelem,1,maxnum_funcvalues_short_atomic,num_funcvalues_short_atomic,minvalue_short_atomic,maxvalue_short_atomic,avvalue_short_atomic,eshortmin,eshortmax,rdummy,rdummy)
            ! read in all data from all weight files
            call readweights(inp_path,0,nelem,maxnum_weights_short_atomic,num_weights_short_atomic,weights_short_atomic)
        end if

        ! read in biases and weights for electrostatic part
        if(lelec.and.(nn_type_elec.eq.1))then
            ! check existance of scalinge.data
            if (.not. file_exists(filename_scalinge)) stop err // err_scalinge // 'file does not exist'
            ! read in all data from scalinge.data
            call readscale(filename_scalinge,err_scalinge,nelem,3,maxnum_funcvalues_elec,num_funcvalues_elec,minvalue_elec,maxvalue_elec,avvalue_elec,dummy,dummy,chargemin,chargemax)
            ! read in all data from all weighte files
            call readweights(inp_path,1,nelem,maxnum_weights_elec,num_weights_elec,weights_elec)
        end if

        ! start according to predict.f90
        if(lshort.and.(nn_type_short.eq.1))then
            allocate(sens(nelem,maxnum_funcvalues_short_atomic))
        endif

        if(lelec.and.(nn_type_elec.eq.1).or.(nn_type_elec.eq.3).or.(nn_type_elec.eq.4))then
          allocate(sense(nelem,maxnum_funcvalues_elec))
        endif
        ! end according to predict.f90

    end subroutine read_nene



    subroutine inputnndefaults()

        implicit none

        if(lshort.and.(nn_type_short.eq.1))then
            nodes_short_atomic(:,:)=0
        endif

        if(lelec.and.(nn_type_elec.eq.1))then
            nodes_elec(:,:)=0
        endif

        if (analyze_error_energy_step == default_real) then
            analyze_error_energy_step = 0.01d0
        end if
        if (analyze_error_force_step == default_real) then
            analyze_error_force_step = 0.01d0
        end if
        if (analyze_error_charge_step == default_real) then
            analyze_error_charge_step = 0.001d0
        end if
        if (paramode == default_int) then
            paramode = 1
        end if
        if (ewaldalpha == default_real) then
            ewaldalpha = 0.0d0
        end if
        if (ewaldcutoff == default_real) then
            ewaldcutoff = 0.0d0
        end if
        if (ewaldkmax == default_int) then
            ewaldkmax = 0
        end if
        if (nenergygroup == default_int) then
            nenergygroup = 1
        end if
        if (nforcegroup == default_int) then
            nforcegroup = 1
        end if
        if (nchargegroup == default_int) then
            nchargegroup = 1
        end if
        if (energyrnd == default_real) then
            energyrnd = 1.0d0
        end if
        if (forcernd == default_real) then
            forcernd = 1.0d0
        end if
        if (chargernd == default_real) then
            chargernd = 1.0d0
        end if
        if (fitethres == default_real) then
            fitethres = 0.0d0
        end if
        if (fitfthres == default_real) then
            fitfthres = 0.0d0
        end if
        if (rmin == default_real) then
            rmin = 0.5d0
        end if
        if (optmodee == default_int) then
            optmodee = 1
        end if
        if (optmodef == default_int) then
            optmodef = 1
        end if
        if (optmodeq == default_int) then
            optmodeq = 1
        end if
        if (nblock == default_int) then
            nblock = 200
        end if
        if (nepochs == default_int) then
            nepochs = 0
        end if
        if (iwriteweight == default_int) then
            iwriteweight = 1
        end if
        if (kalmanthreshold == default_real) then
            kalmanthreshold = 0.0d0
        end if
        if (kalmanthresholdf == default_real) then
            kalmanthresholdf = 0.0d0
        end if
        if (kalmanthresholde == default_real) then
            kalmanthresholde = 0.0d0
        end if
        if (kalmanthresholdc == default_real) then
            kalmanthresholdc = 0.0d0
        end if
        if (kalman_dampe == default_real) then
            kalman_dampe = 1.0d0
        end if
        if (kalman_dampf == default_real) then
            kalman_dampf = 1.0d0
        end if
        if (kalman_dampq == default_real) then
            kalman_dampq = 1.0d0
        end if
        if (steepeststepe == default_real) then
            steepeststepe = 0.01d0
        end if
        if (steepeststepf == default_real) then
            steepeststepf = 0.01d0
        end if
        if (steepeststepq == default_real) then
            steepeststepq = 0.01d0
        end if
        if (scalefactorf == default_real) then
            scalefactorf = 1.d0
        end if
        if (ngrowth == default_int) then
            ngrowth = 0
        end if
        if (growthstep == default_int) then
            growthstep = 1
        end if
        if (dampw == default_real) then
            dampw = 0.0d0
        end if
        if (all(atomrefenergies == default_real)) then
            atomrefenergies(:) = 0.0d0
        end if
        if (weights_min == default_real) then
            weights_min = -1.d0
        end if
        if (weights_max == default_real) then
            weights_max = 1.d0
        end if
        if (biasweights_min == default_real) then
            biasweights_min = -1.d0
        end if
        if (biasweights_max == default_real) then
            biasweights_max = 1.d0
        end if
        if (weightse_min == default_real) then
            weightse_min = -1.d0
        end if
        if (weightse_max == default_real) then
            weightse_max = 1.d0
        end if
        if (fitting_unit == default_int) then
            fitting_unit = 1
        end if
        if (pstring == default_string) then
            pstring = '00000000000000000000'
        end if
        if (nran == default_int) then
            nran = 5
        end if
        if (all(fixedcharge == default_real)) then
            fixedcharge(:) = 99.0d0
        end if
        if (maxforce == default_real) then
            maxforce = 10000.d0
        end if
        if (maxenergy == default_real) then
            maxenergy = 10000.d0
        end if
        if (restrictw == default_real) then
            restrictw = -100000.d0
        end if
        if (fitmode == default_int) then
            fitmode = 1
        end if
        if (scmin_short_atomic == default_real) then
            scmin_short_atomic = 0.0d0
        end if
        if (scmax_short_atomic == default_real) then
            scmax_short_atomic = 1.0d0
        end if
        if (scmin_elec == default_real) then
            scmin_elec = 0.0d0
        end if
        if (scmax_elec == default_real) then
            scmax_elec = 1.0d0
        end if
        if (noisee == default_real) then
            noisee = 0.0d0
        end if
        if (noisef == default_real) then
            noisef = 0.0d0
        end if
        if (noiseq == default_real) then
            noiseq = 0.0d0
        end if
        if (cutoff_type == default_int) then
            cutoff_type = 1
        end if
        if (cutoff_alpha == default_real) then
            cutoff_alpha = 0.0d0
        end if
        if (rscreen_cut == default_real) then
            rscreen_cut = 0.0d0
        end if
        if (rscreen_onset == default_real) then
            rscreen_onset = 0.0d0
        end if
        if (dynforcegroup_start == default_int) then
            dynforcegroup_start = 20
        end if
        if (dynforcegroup_step == default_int) then
            dynforcegroup_step = 2
        end if
        if (nshuffle_weights_short_atomic == default_int) then
            nshuffle_weights_short_atomic = 10
        end if
        if (shuffle_weights_short_atomic == default_real) then
            shuffle_weights_short_atomic = 0.1d0
        end if
        if (saturation_threshold == default_real) then
            saturation_threshold = 0.99d0
        end if
        if (dataclusteringthreshold1 == default_real) then
            dataclusteringthreshold1 = 1.0d0
        end if
        if (dataclusteringthreshold2 == default_real) then
            dataclusteringthreshold2 = 0.0d0
        end if
        if (inputforcethreshold == default_real) then
            inputforcethreshold = 0.001d0
        end if
        if (kalman_epsilon == default_real) then
            kalman_epsilon = 1.0d0
        end if
        if (kalman_q0 == default_real) then
            kalman_q0 = 0.0d0
        end if
        if (kalman_qtau == default_real) then
            kalman_qtau = 0.0d0
        end if
        if (kalman_qmin == default_real) then
            kalman_qmin = 0.0d0
        end if

    end subroutine inputnndefaults

    subroutine checkinputnn(err_main,err_file)

        implicit none

        integer counter

        character(len=*), parameter, intent(in) :: err_main, err_file
        character(len=*), parameter,            :: err_check = "Error in checkinputnn: "


        if (nran .neq. 5) then
            print *, err_main, err_file, err_check, "random_number_type not implemented, only 5 available"
        end if

      if(lfindcontradictions)then
        if(deltagthres.gt.0.0d0)then
          write(*,*)'ERROR: find_contradictions requires positive deltagthres ',&
            deltagthres
          stop
        endif
        if(deltafthres.gt.0.0d0)then
          write(*,*)'ERROR: find_contradictions requires positive deltafthres ',&
            deltafthres
          stop
        endif
      endif

      if((cutoff_alpha.gt.1.00000001d0).or.(cutoff_alpha.lt.0.0d0))then
        write(*,*)'ERROR: please use cutoff_alpha within 0 and 1 ',cutoff_alpha
        stop
      endif

      if(lusenoisematrix) then
        if((kalman_q0 .le. 0.0d0 ).or.(kalman_qmin.le.0.0d0).or.(kalman_qtau.le.0.0d0)) then
          write(*,*)'ERROR: please define the q0,qmin,qtau for noise matrix ', &
          'and use them larger than zero ',kalman_q0,kalman_qmin,kalman_qtau
          stop
        endif
      endif

      if(lfixweights.and.lshuffle_weights_short_atomic)then
        write(*,*)'ERROR: shuffle_weights_short_atomic cannot be combined with fixed weights'
        stop
      endif

      if(lscreen)then
        if(rscreen_onset.gt.rscreen_cut)then
          write(*,*)'ERROR: rscreen_onset .gt. rscreen_cut in screen_electrostatics'
          stop
        endif
        if(rscreen_onset.lt.0.0d0)then
          write(*,*)'ERROR: rscreen_onset .lt. 0 in screen_electrostatics'
          stop
        endif
        if(rscreen_cut.lt.0.0d0)then
          write(*,*)'ERROR: rscreen_cut .lt. 0 in screen_electrostatics'
          stop
        endif
      endif

      if(noisee.lt.0.0d0)then
        write(*,*)'ERROR: noise_energy must not be negative ',noisee
        stop
      endif

      if(noisef.lt.0.0d0)then
        write(*,*)'ERROR: noise_force must not be negative ',noisef
        stop
      endif

      if(noiseq.lt.0.0d0)then
        write(*,*)'ERROR: noise_charge must not be negative ',noiseq
        stop
      endif

      if(lsysweights.and.lnwweights)then
        write(*,'(a)')'Error: Cannot use systematic_weights_short and nguyen_widrow_weights_short together!'
        stop
      endif

      if(lsysweightse.and.lnwweightse)then
        write(*,'(a)')'Error: Cannot use systematic_weights_ewald and nguyen_widrow_weights_ewald together!'
        stop
      endif

      if(lnormnodes.and.lnwweights)then
        write(*,'(a)')'Error: Cannot use normalize_nodes and nguyen_widrow_weights_short together!'
        stop
      endif

      if(lnormnodes.and.lnwweightse)then
        write(*,'(a)')'Error: Cannot use normalize_nodes and nguyen_widrow_weights_ewald together!'
        stop
      endif

      if((count_kalmanthreshold.eq.1).and.(count_lfixederrore.eq.1))then
        write(*,'(2a)')'Error: short_energy_error_threshold cannot be used ',&
          'in combination with fixed_short_energy_error_threshold'
        stop
      endif

      if((count_kalmanthresholdf.eq.1).and.(count_lfixederrorf.eq.1))then
        write(*,'(a)')'Error: short_force_error_thresholdf cannot be used in combination with fixed_short_force_error_threshold'
        stop
      endif

      if(count_mode.eq.0)then
        write(*,*)'Error: runner_mode is not specified'
        stop
      endif

      if((.not.lshort).and.(.not.lelec))then
        write(*,*)'Error: short range and electrostatic NNs are switched off'
        stop
      endif

      if(lshort.and.(maxnum_layers_short_atomic.eq.0).and.(nn_type_short.eq.1))then
        write(*,*)'Error: global_hidden_layers_short is not specified'
        stop
      endif

      if(lshort.and.(maxnum_layers_short_pair.eq.0).and.(nn_type_short.eq.2))then
        write(*,*)'Error: global_hidden_layers_pair is not specified'
        stop
      endif

      if(lelec.and.(nn_type_elec.eq.0))then
        write(*,*)'Error: electrostatic_type is not specified'
        stop
      endif

      if(lelec.and.(nn_type_elec.eq.1).and.(maxnum_layers_elec.eq.0))then
        write(*,*)'Error: global_hidden_layers_electrostatic is not specified'
        stop
      endif

      if(lshort.and.(count_nodes_short_atomic.eq.0).and.(nn_type_short.eq.1))then
        write(*,*)'Error: global_nodes_short is not specified'
        stop
      endif

      if(lelec.and.(nn_type_elec.eq.1).and.(count_nodes_elec.eq.0))then
        write(*,*)'Error: global_nodes_electrostatic is not specified'
        stop
      endif

      if(lshort.and.(count_nodes_short_pair.eq.0).and.(nn_type_short.eq.2))then
        write(*,*)'Error: global_nodes_pair is not specified'
        stop
      endif

      do i1=1,nelem
        if(lshort.and.(nn_type_short.eq.1))then
          if(nodes_short_atomic(maxnum_layers_short_atomic,i1).gt.1)then
            write(*,*)'Error: More than 1 output node currently does '
            write(*,*)'make sense in short range NN'
            stop
          endif
        endif
      enddo ! i1

      do i1=1,nelem
        if(lshort.and.(nn_type_short.eq.1))then
          if(nodes_short_atomic(maxnum_layers_short_atomic,i1).eq.0)then
            write(*,*)'Error: output_nodes_short is 0'
            stop
          endif
        endif
      enddo ! i1

      do i1=1,nelem
        if(lelec.and.(nn_type_elec.eq.1))then
          if(nodes_elec(maxnum_layers_elec,i1).gt.1)then
            write(*,*)'Error: More than 1 output node currently does '
            write(*,*)'make sense in electrostatic NN'
            stop
          endif
        endif
      enddo ! i1

      do i1=1,nelem
        if(lelec.and.(nn_type_elec.eq.1))then
          if(nodes_elec(maxnum_layers_elec,i1).eq.0)then
            write(*,*)'Error: output_nodes_electrostatic is 0'
            stop
          endif
        endif
      enddo ! i1

      do i1=1,nelem
        if(lshort.and.(nn_type_short.eq.1))then
          if(nodes_short_atomic(0,i1).eq.0)then
            write(*,*)'Error: input_nodes_short is 0'
            stop
          endif
        endif
      enddo ! i1

      do i1=1,nelem
        if(lshort.and.(nn_type_short.eq.1))then
          if(nodes_short_atomic(0,i1).ne.num_funcvalues_short_atomic(i1))then
            write(*,*)'Error: num_funcvalues_short_atomic .ne. nodes_short_atomic(0)',&
              num_funcvalues_short_atomic(i1),nodes_short_atomic(0,i1)
            write(*,*)'Did you set the right number of input nodes?'
            stop
          endif
        endif
      enddo ! i1

      do i1=1,nelem
        if(lelec.and.(nn_type_elec.eq.1))then
          if(nodes_elec(0,i1).eq.0)then
            write(*,*)'Error: input_nodes_electrostatic is 0'
            stop
          endif
        endif
      enddo ! i1

      do i1=1,nelem
        if(lelec.and.(nn_type_elec.eq.1))then
          if(nodes_elec(0,i1).ne.num_funcvalues_elec(i1))then
            write(*,*)'Error: num_funcvalues_elec .ne. nodes_elec(0)',&
              num_funcvalues_elec(i1),nodes_elec(0,i1)
            write(*,*)'Did you set the right number of input nodes?'
            stop
          endif
        endif
      enddo ! i1

      if(lshort.and.(nn_type_short.eq.1))then
        if(count_global_activation_short_atomic.eq.0)then
          write(*,*)'Error: global_activation_short is not specified'
          stop
        endif
      endif

      if(lelec.and.(nn_type_elec.eq.1))then
        if(count_global_activation_elec.eq.0)then
          write(*,*)'Error: global_activation_ewald is not specified'
          stop
        endif
      endif

      if(lelec.and.(count_ewaldalpha.eq.0))then
        write(*,*)'Error: ewald_alpha must be specified for electrostatic NN'
        stop
      endif

      if(lelec.and.(ewaldalpha.le.0))then
        write(*,*)'Error: ewald_alpha must be positive ',ewaldalpha
        stop
      endif
!!
      if(lelec.and.(count_ewaldcutoff.eq.0))then
        write(*,*)'Error: ewald_cutoff must be specified for electrostatic NN'
        stop
      endif
!!
      if(lelec.and.(ewaldcutoff.le.0))then
        write(*,*)'Error: ewald_cutoff must be positive ',ewaldcutoff
        stop
      endif
!!
      if(lelec.and.(count_ewaldkmax.eq.0))then
        write(*,*)'Error: ewald_kmax must be specified for electrostatic NN'
        stop
      endif
!!
      if((.not.lshort).and.(luseforces))then
        write(*,*)'### WARNING ### switching off use_short_forces because no short range NN is used'
        luseforces=.false.
      endif
!!
      if(lelec.and.(.not.luseatomcharges))then
        write(*,*)'### WARNING ### use_atom_charges is switched on for electrostatic NN'
        luseatomcharges=.true.
      endif
!!
      if(lshort.and.(luseatomenergies))then
        write(*,*)'### WARNING ### use_atom_energies is switched off (not implemented)'
        luseatomenergies=.false.
      endif
!!
      if((.not.lshort).and.(lremoveatomenergies))then
        write(*,*)'### WARNING ### remove_atom_energies is switched on without short range NN'
      endif
!!
      if(lelec.and.(lchargeconstraint))then
        write(*,'(a)')' ### WARNING ### use_charge_constraint is not maintained at the moment and might fail'
      endif
!!
      if(count_iseed.eq.0)then
        write(*,*)'### WARNING ### no random_seed specified, using default '
      endif
!!
      if(nenergygroup.gt.nblock)then
        nenergygroup=nblock
        write(*,*)'### WARNING ### reducing nenergygroup to nblock'
      endif

      if(count_nelem.eq.0)then
        write(*,*)'Error: number_of_elements not specified'
        stop
      endif
!!
      if(count_element.eq.0)then
        write(*,*)'Error: elements not specified'
        stop
      endif
!!
      if((mode.eq.1).and.(count_splitthres.eq.0))then
        write(*,*)'Error: test_fraction not specified'
        stop
      endif
!!
      if(lcentersym.and.(count_scmin_short_atomic.gt.0))then
        write(*,'(a)')'Error: center_symmetry_functions cannot be combined with scale_min_short_atomic keyword'
        stop
      endif
!!
      if(lcentersym.and.(count_scmax_short_atomic.gt.0))then
        write(*,'(a)')'Error: center_symmetry_functions cannot be combined with scale_max_short_atomic keyword'
        stop
      endif
!!
      if(lcentersym.and.(count_scmin_short_pair.gt.0))then
        write(*,'(a)')'Error: center_symmetry_functions cannot be combined with scale_min_short_pair keyword'
        stop
      endif
!!
      if(lcentersym.and.(count_scmax_short_pair.gt.0))then
        write(*,'(a)')'Error: center_symmetry_functions cannot be combined with scale_max_short_pair keyword'
        stop
      endif
!!
      if(lcentersym.and.(count_scmin_elec.gt.0))then
        write(*,'(a)')'Error: center_symmetry_functions cannot be combined with scale_min_elec keyword'
        stop
      endif
!!
      if(lcentersym.and.(count_scmax_elec.gt.0))then
        write(*,'(a)')'Error: center_symmetry_functions cannot be combined with scale_max_elec keyword'
        stop
      endif
!!
      if((count_scmin_short_atomic.gt.0).and.(.not.lscalesym))then
        write(*,*)'Error: scale_min_short requires keyword scale_symmetry_functions'
        stop
      endif
!!
      if((count_scmax_short_atomic.gt.0).and.(.not.lscalesym))then
        write(*,*)'Error: scale_max_short requires keyword scale_symmetry_functions'
        stop
      endif
!!
      if((count_scmin_short_pair.gt.0).and.(.not.lscalesym))then
        write(*,*)'Error: scale_min_short_pair requires keyword scale_symmetry_functions'
        stop
      endif
!!
      if((count_scmax_short_pair.gt.0).and.(.not.lscalesym))then
        write(*,*)'Error: scale_max_short_pair requires keyword scale_symmetry_functions'
        stop
      endif
!!
      if((count_scmin_elec.gt.0).and.(.not.lscalesym))then
        write(*,*)'Error: scale_min_elec requires keyword scale_symmetry_functions'
        stop
      endif
!!
      if((count_scmax_elec.gt.0).and.(.not.lscalesym))then
        write(*,*)'Error: scale_max_elec requires keyword scale_symmetry_functions'
        stop
      endif
!!
      if(scmin_short_atomic.ge.scmax_short_atomic)then
        write(*,'(a)')'Error: scale_min_short .ge. scale_max_short'
        stop
      endif
!!
      if(scmin_short_pair.ge.scmax_short_pair)then
        write(*,'(a)')'Error: scale_min_short_pair .ge. scale_max_short_pair'
        stop
      endif
!!
      if(scmin_elec.ge.scmax_elec)then
        write(*,'(a)')'Error: scale_min_elec .ge. scale_max_elec'
        stop
      endif
!!
      if(lupdatebyelement.and.lchargeconstraint)then
        lchargeconstraint=.false.
        if(mode.eq.2)then
          write(*,*)'### WARNING ### lchargeconstraint is switched off because of lupdatebyelement'
        endif
      endif
!!
      if(lshort.and.lupdatebyelement.and.(mode.eq.2))then
        write(*,*)'### WARNING ### lupdatebyelement works only for charges and forces'
      endif
!!
      if(luseworste.and.lshort.and.(energyrnd.lt.1.0d0))then
        energyrnd=1.0d0
        write(*,*)'### WARNING ### luseworste overrides energyrnd: ',energyrnd
      endif
!!
      if(luseworstf.and.lshort.and.luseforces.and.(forcernd.lt.1.0d0))then
        forcernd=1.0d0
        write(*,*)'### WARNING ### luseworstf overrides forcernd: ',forcernd
      endif
!!
      if(luseworstq.and.lelec.and.(nn_type_elec.eq.1).and.(chargernd.lt.1.0d0))then
        chargernd=1.0d0
        write(*,*)'### WARNING ### luseworstq overrides chargernd: ',chargernd
      endif
!!
      if(dampw.gt.1.0d0)then
        write(*,*)'Error: dampw must not be larger than 1.0d0 ',dampw
        stop
      endif
!!
      if(ldostress.and.(.not.ldoforces))then
        write(*,*)'### WARNING ### Analytic stress is requested without forces'
        write(*,*)'Switching on calculation of analytic forces'
        ldoforces=.true.
      endif
!!
      if(ldohessian.and.(.not.ldoforces))then
        write(*,*)'### WARNING ### Analytic Hessian is requested without forces'
        write(*,*)'Switching on calculation of analytic forces'
        ldoforces=.true.
      endif
!!
      if(ldostress.and.(mode.eq.1))then
        write(*,*)'### WARNING ### switching off stress calculation in mode 1 for increased performance'
        ldostress=.false.
      endif
!!
      if((count_wconstraint.gt.0).and.(.not.lfixweights))then
        write(*,*)'ERROR: weight constraints are specified without fix_weights keyword'
        stop
      endif

      if((count_wconstraint.eq.0).and.(lfixweights))then
        write(*,*)'ERROR: no weights constrained but keyword fix_weights has been selected'
        stop
      endif
!!
      if(weights_min.ge.weights_max)then
        write(*,*)'ERROR: weights_min > weights_max'
        stop
      endif
!!
      if(biasweights_min.ge.biasweights_max)then
        write(*,*)'ERROR: biasweights_min > biasweights_max'
        stop
      endif
!!
      if(weightse_min.ge.weightse_max)then
        write(*,*)'ERROR: weightse_min > weightse_max'
        stop
      endif
!!
      if(kalman_dampe.lt.0.0d0)then
        write(*,*)'ERROR: kalman_damp_short must be non-negative ',kalman_dampe
        stop
      endif
!!
      if(kalman_dampf.lt.0.0d0)then
        write(*,*)'ERROR: kalman_damp_force must be non-negative ',kalman_dampf
        stop
      endif
!!
      if(kalman_dampq.lt.0.0d0)then
        write(*,*)'ERROR: kalman_damp_charge must be non-negative ',kalman_dampq
        stop
      endif
!!
      if(ljointefupdate.and.lelec)then
        write(*,*)'ERROR: joint_energy_force_update is not implemented for lelec and nn_type_elec 2'
        stop
      endif
!!
      if(ljointefupdate)then
        if(optmodee.ne.optmodef)then
          write(*,*)'ERROR: joint_energy_force_update requires to use the'
          write(*,*)'same optimization algorithm for energy and forces'
          stop
        endif
        if(.not.luseforces)then
          write(*,*)'ERROR: switch on use_short_forces for joint_energy_force_update'
          stop
        endif
        if(lrepeate)then
          write(*,*)'ERROR: repeated energy update cannot be combined with joint energy and force update'
          stop
        endif
        if(forcernd.lt.1.0d0)then
          write(*,*)'ERROR: joint energy and force update requires force_fraction = 1.0d0'
          stop
        endif
        if(luseworste)then
          write(*,*)'ERROR: joint energy and force update cannot be combined with update_worst_short_energies'
          stop
        endif
        if(luseworstf)then
          write(*,*)'ERROR: joint energy and force update cannot be combined with update_worst_short_forces'
          stop
        endif
        if(nenergygroup.gt.1)then
          write(*,*)'ERROR: joint energy and force update cannot be combined with short_energy_group > 1'
          stop
        endif
        if(nforcegroup.gt.1)then
          write(*,*)'ERROR: joint energy and force update cannot be combined with short_force_group > 1'
          stop
        endif
        if(kalmanthresholdf.gt.0.0d0)then
          write(*,*)'ERROR: joint energy and force update cannot be combined with short_force_error_threshold > 0.0'
          stop
        endif
      endif
!!
      if(maxforce.le.0.0d0)then
        write(*,*)'ERROR: max_force must not be negative ',maxforce
        stop
      endif
!!
      if(lshort.and.(nn_type_short.eq.1))then
        do i1=1,nelem
          if(num_funcvalues_short_atomic(i1).ne.nodes_short_atomic(0,i1))then
            write(*,*)'ERROR: num_funcvalues_short_atomic .ne. nodes_short_atomic(0)'
            write(*,*)i1,num_funcvalues_short_atomic(i1),nodes_short_atomic(0,i1)
            stop
          endif
        enddo! i1
      endif
!!
      if(lelec.and.(nn_type_elec.eq.1))then
        do i1=1,nelem
          if(num_funcvalues_elec(i1).ne.nodes_elec(0,i1))then
            write(*,*)'ERROR: num_funcvalues_elec .ne. nodes_elec(0)'
            write(*,*)i1,num_funcvalues_elec(i1),nodes_elec(0,i1)
            stop
          endif
        enddo ! i1
      endif
!!
      if((nn_type_elec.eq.4).and.(mode.ne.3))then
        write(*,*)'ERROR: electrostatic_type 4 is only valid for prediction mode'
        stop
      endif
!!
      if((mode.eq.3).and.(max_num_atoms.lt.nblock).and.(nn_type_short.eq.1).and.lshort)then
        write(*,*) 'WARNING: reducing points_in_memory to max_num_atoms ',max_num_atoms
        nblock=max_num_atoms
      endif

    end subroutine checkinputnn

    subroutine printinputnn(iseed,ielem,nodes_short_atomic_temp,nodes_elec_temp,kalmanlambda_local,kalmanlambdae_local,actfunc_short_atomic_dummy,actfunc_elec_dummy)

        ! check counter from inputnncounters, they should be removed and replaced by our default values!!

        implicit none


        integer i
        integer cnt_1, cnt_2, cnt_3
        integer nodes_short_atomic_temp(0:maxnum_layers_short_atomic)
        integer nodes_elec_temp(0:maxnum_layers_elec)

        real*8 kalmanlambda_local
        real*8 kalmanlambdae_local

        character*1 actfunc_short_atomic_dummy(maxnum_layers_short_atomic)
        character*1 actfunc_elec_dummy(maxnum_layers_elec)

        write(*,*)'General input parameters:'
        write(*,*)'-------------------------------------------------------------'

        if(lshort)then
            write(*,*)'Short range NN is on'
        else
            write(*,*)'Short range NN is off'
        endif

        if(lelec.and.(nn_type_elec.eq.1))then
            write(*,*)'Electrostatic NN is on'
        else
            write(*,*)'Electrostatic NN is off'
        endif

        if(lvdw.and.(nn_type_vdw.eq.1))then
            write(*,*)'vdW corrections switched on'
        else
            write(*,*)'vdW corrections switched off'
        endif

        if((mode.eq.1).and.lcheckinputforces)then
            write(*,'(a,f10.6,a)')&
            ' checking input forces, threshold for force vector is  '&
            ,inputforcethreshold,' Ha/Bohr'
        endif

        write(*,*)'-------------------------------------------------------------'

        if(lshort)then
            if(nn_type_short.le.2)then
                write(*,'(a55,i2)')&
                    ' RuNNer nn_type_short                                              ',nn_type_short
            else
                write(*,*)'ERROR: unknown nn_type_short: ',nn_type_short
                stop
            endif
        endif

        if(mode.eq.1)then
            write(*,*)'RuNNer is started in mode for symmetry function calculation (1)'
        elseif(mode.eq.2)then !'
            write(*,*)'RuNNer is started in mode for fitting (2)'
        elseif(mode.eq.3)then
            write(*,*)'RuNNer is started in mode for prediction (3)'
        else
            write(*,*)'ERROR: Unknown runner_mode: ',mode
            stop
        endif

        write(*,'(a,l)')' debugging mode is                                       ',ldebug

        write(*,'(a,i4)')' parallelization mode                                  ',paramode

        write(*,'(a,l)')' enable detailed time measurement                        ',lfinetime

        if(mode.eq.2)then
            write(*,'(a,l)')' enable detailed time measurement at epoch level         ',lfinetimeepoch
        endif

        write(*,'(a,l)')' silent mode                                             ',lsilent

        if((mode.eq.2).or.(mode.eq.3))then
            write(*,'(a,l)')' NN force check                                          ',lcheckf
        endif

      if(nelem.lt.ielem)then
        write(*,*)'ERROR: number of elements in structure(s) is larger than '
        write(*,*)'number of elements in input.nn ',ielem,nelem
        stop
      else
        write(*,'(a,i4)')' number of elements                                    ',nelem
      endif

      write(*,*)'elements (sorted):'
      do i1=1,nelem
        write(*,'(i3,x,a2)')nucelem(i1),element(i1)
      enddo


      write(*,'(a,i10)')' seed for random number generator                ',iseed

      if((nran.lt.0).or.(nran.gt.5))then
        write(*,*)'ERROR: Unknown random number generator ',nran
        stop
      endif
      write(*,'(a,i10)')' random number generator type                    ',nran

      write(*,'(a,l)')' remove free atom reference energies                     ',lremoveatomenergies

      if(lfitethres.and.(mode.eq.1))then
        write(*,'(a,f7.3)')' upper energy threshold per atom (Ha)               ',fitethres
      endif

      if(lfitfthres.and.(mode.eq.1))then
        write(*,'(a,f7.3)')' max force component threshold (Ha/Bohr)            ',fitfthres
      endif

      write(*,'(a,f8.3)')' shortest allowed bond in structure                ',rmin

      if(lnormnodes)then
        write(*,*)'Linear combinations at nodes are normalized'
      endif

      write(*,'(a,i3)')' Cutoff_type for symmetry function is                   ',cutoff_type
      write(*,'(a,f7.3)')' Cutoff_alpha for inner cutoff radius is            ',cutoff_alpha

      if(lenforcemaxnumneighborsatomic)then
        write(*,'(a,i3)')&
        ' Enforcing global max_num_neighors_atomic               ',max_num_neighbors_atomic_input
      endif

      if(lshort.and.(mode.ne.1))then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'Short range NN specifications:'
        write(*,*)'-------------------------------------------------------------'
      endif

      if(lshort.and.(nn_type_short.eq.1).and.(mode.ne.1))then
        write(*,'(a,10i5)')' global hidden layers short range NN                  ',maxnum_layers_short_atomic-1
        write(*,'(a,10i5)')' global nodes hidden layers short NN             ',&
          (nodes_short_atomic_temp(i1),i1=1,maxnum_layers_short_atomic-1)
      endif

      if(lshort.and.(nn_type_short.eq.1).and.(mode.ne.1))then
        write(*,'(a,x,10a)')' global activation functions short                     ',&
          (actfunc_short_atomic_dummy(i),i=1,maxnum_layers_short_atomic)
      endif

      if(lshort.and.(nn_type_short.eq.2).and.(mode.ne.1))then
        write(*,'(a,10i5)')' global hidden layers short range NN pair             ',maxnum_layers_short_pair-1
        write(*,'(a,10i5)')' global nodes hidden layers short NN pair        ',&
          (nodes_short_pair_temp(i1),i1=1,maxnum_layers_short_pair-1)
      endif

      if(lshort.and.(nn_type_short.eq.2).and.(mode.ne.1))then
        write(*,'(a,x,10a)')' global activation functions short pair                ',&
          (actfunc_short_pair_dummy(i),i=1,maxnum_layers_short_pair)
      endif

      if(lelec)then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'Electrostatic specifications:'
        write(*,*)'-------------------------------------------------------------'
      endif

      if(lelec)then
        write(*,'(a,i5)')' electrostatic_type (nn_type_elec)                    ',nn_type_elec
        if(nn_type_elec.eq.1)then
          write(*,'(a)')' Using separate set of atomic NNs for atomic charges'
        elseif(nn_type_elec.eq.2)then
          write(*,'(a)')' Constructing atomic charges from short range NN'
        elseif(nn_type_elec.eq.3)then
          write(*,'(a)')' Fixed atomic charges are used:'
          do i1=1,nelem
            write(*,'(a1,a2,x,f14.3)')' ',element(i1),fixedcharge(i1)
          enddo
        elseif(nn_type_elec.eq.4)then
          write(*,'(a)')' Using atomic charges from charges.in file'
        else
          write(*,*)'ERROR: Unknown electrostatic_type ',nn_type_elec
          stop
        endif
      endif

      if(lelec.and.(nn_type_elec.eq.1))then
        write(*,'(a,10i5)')' global hidden layers electrostatic NN                ',maxnum_layers_elec-1
        write(*,'(a,10i5)')' global nodes hidden layers electrostatic NN     ',&
          (nodes_elec_temp(i1),i1=1,maxnum_layers_elec-1)
      endif

      if(lelec.and.(nn_type_elec.eq.1))then
        write(*,'(a,x,10a)')' global activation functions electrostatic             ',&
          (actfunc_elec_dummy(i),i=1,maxnum_layers_elec)
      endif

      if(lelec)then
        write(*,'(a,f8.3)')' Ewald alpha                                       ',ewaldalpha
        write(*,'(a,f8.3)')' Ewald cutoff                                      ',ewaldcutoff
        write(*,'(a,i6)')' Ewald kmax                                          ',ewaldkmax
      endif

      if(lelec.and.(mode.eq.0))then
        write(*,'(a,i4)')' Enforce total charge                                ',enforcetotcharge
      endif

      if(lelec)then
        if(lscreen)then
          write(*,'(a,2f14.6)')' Screening electrostatics                            ',rscreen_onset,rscreen_cut
        else
          write(*,'(a)')' No screening of electrostatics requested                '
        endif
      endif

      if(lelec)then
        if(mode.eq.3)then
          if(nn_type_elec.eq.4)then
            write(*,'(a)')' Using atomic charges from file charges.in!'
          endif
        endif
      endif


      if(lvdw)then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'vdW specifications:'
        write(*,*)'-------------------------------------------------------------'
      endif

      if(lvdw)then
        write(*,'(a,i4)')' vdW type                                            ',nn_type_vdw
      endif
      if(lvdw.and.(nn_type_vdw.eq.1))then
        write(*,'(a,2f14.6)')' vdw screening                                       ',vdw_screening(1),vdw_screening(2)
      endif







      if(lshort.and.(mode.eq.1))then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'Parameters for symmetry function generation: short range part:'
        write(*,*)'-------------------------------------------------------------'
      endif

      if(lshort.and.(mode.eq.1)) write(*,'(a,l)')&
        ' using forces for fitting                                ',luseforces

      if(lshort.and.(mode.eq.1)) write(*,'(a,l)')&
        ' using atomic energies for fitting                       ',luseatomenergies

      if(lelec.and.(mode.eq.1))write(*,'(a,l)')&
        ' using atomic charges for fitting                        ',luseatomcharges

      if(mode.eq.1)then
        write(*,*)'-------------------------------------------------------------'
        write(*,'(a,f8.4)') ' percentage of data for testing (%)                ',&
          100.d0*splitthres
      endif

      if(mode.eq.2)then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'General fitting parameters:'
        write(*,*)'-------------------------------------------------------------'
      endif

      if(mode.eq.2)then
        write(*,'(a,i8)')' number of fitting epochs                          ',nepochs
      endif ! mode.eq.2

      if(mode.eq.2)then
        write(*,'(a,l)')' print date and time for each epoch                      ',lprintdateandtime
      endif ! mode.eq.2

      if((mode.eq.2).and.lenableontheflyinput)then
        write(*,'(a,i8)')' on-the-fly input enabled          '
      endif ! mode.eq.2

      if(mode.eq.2)then
        write(*,'(a,i8)')' number of data sets in memory                     ',nblock
      endif ! mode.eq.2

      if(mode.eq.2)then
        if(fitmode.eq.1)then
          write(*,'(a,i8)')' Fitting mode 1 (online learning) selected         '
        elseif(fitmode.eq.2)then
          write(*,'(a,i8)')' Fitting mode 2 (offline learning) selected        '
        endif
      endif ! mode.eq.2

      if(mode.eq.2)then
        write(*,'(a,l)')' Randomly mixing all points in training set              ',lmixpoints
      endif

      if(mode.eq.2)write(*,'(a,l)')' save Kalman filter data                                 ',lsavekalman

      if(mode.eq.2)write(*,'(a,l)')' restart from old Kalman filter data                     ',lrestkalman

      if(mode.eq.2)write(*,'(a,l)')' rescale symmetry functions                              ',lscalesym

      if((mode.eq.2).and.lscalesym.and.lshort.and.(nn_type_short.eq.1))then
        write(*,'(a,f10.3)')' min value of scaled short range symmetry functions ',scmin_short_atomic
        write(*,'(a,f10.3)')' max value of scaled short range symmetry functions ',scmax_short_atomic
      endif

      if((mode.eq.2).and.lscalesym.and.lshort.and.(nn_type_short.eq.2))then
        write(*,'(a,f10.3)')' min value of scaled pair symmetry functions       ',scmin_short_pair
        write(*,'(a,f10.3)')' max value of scaled pair symmetry functions       ',scmax_short_pair
      endif

      if((mode.eq.2).and.lscalesym.and.lelec.and.(nn_type_elec.eq.1))then
        write(*,'(a,f10.3)')' min value of scaled electrostatic symmetry functions ',scmin_elec
        write(*,'(a,f10.3)')' max value of scaled electrostatic symmetry functions ',scmax_elec
      endif

      if(mode.eq.2)write(*,'(a,l)')&
        ' remove CMS from symmetry functions                      ',lcentersym

      if(mode.eq.2)write(*,'(a,l)')&
        ' calculate symmetry function correlation                 ',lpearson_correlation

      if(mode.eq.2)write(*,'(a,l)')&
        ' weight analysis                                         ',lweightanalysis

      if(mode.eq.2)write(*,'(a,l)')&
        ' environment analysis                                    ',lenvironmentanalysis

      if(mode.eq.2)write(*,'(a,l)')&
        ' find contradictions                                     ',lfindcontradictions
      if((mode.eq.2).and.lfindcontradictions)then
        write(*,'(a,f10.3)')' threshold for |deltaG|                            ',deltagthres
        write(*,'(a,f10.3)')' threshold for delta|F|                            ',deltafthres
      endif

      if(mode.eq.2)write(*,'(a,l)')' fix some weights                                        ',lfixweights

      if(mode.eq.2)write(*,'(a,l)')' using growth mode for fitting                           ',lgrowth
      if((mode.eq.2).and.lgrowth)then
        write(*,'(a,i8)')' number of training structures in each growth step ',ngrowth
      endif
      if(lgrowth.and.(mode.eq.2))then
        write(*,'(a,i4)')' epochs with constant training set size in growth mode ',growthstep
      endif

      if((mode.eq.2).and.ldampw)then
        write(*,'(a,l)')' using weight decay                                      ',ldampw
        write(*,'(a,f18.12)')' balance between error and weight decay  ',dampw
      endif

      if((mode.eq.2).and.lupdatebyelement)then
        write(*,'(a,i3)')' do weight update just for one element                  ',elemupdate
        write(*,*)'### WARNING ### RMSEs will refer only to this element'
      endif

      if(mode.eq.2)write(*,'(a,l)')&
        ' global fit of short and charge NN (not implemented)     ',lglobalfit

      if(mode.eq.2)then
        if(fitting_unit.eq.1)then
          write(*,'(a,a2)')' error unit for fitting                                  ','eV'
        elseif(fitting_unit.eq.2)then
          write(*,'(a,a2)')' error unit for fitting                                  ','Ha'
        else
          write(*,*)'ERROR: add new energy unit in output of readinput.f90!!!'
          stop
        endif
      endif

      if(mode.eq.2)then
        if(lreadunformatted)then
          write(*,'(a)')' Reading unformatted files '
        else
          write(*,'(a)')' Reading formatted files '
        endif
      endif

      if(mode.eq.2)then
        if(lwriteunformatted)then
          write(*,'(a)')' Writing unformatted files '
        else
          write(*,'(a)')' Writing formatted files '
        endif
      endif

      if(mode.eq.2)then
        if((optmodee.eq.1).or.(optmodef.eq.1).or.(optmodeq.eq.1))then
          write(*,'(a,l)')' Resetting Kalman filter matrices each epoch             ',lresetkalman
        endif
      endif

      if(mode.eq.2)then
        if(nn_type_short.eq.1)then
          if(lshuffle_weights_short_atomic)then
            write(*,'(a,i5,f14.6)')' shuffle_weights_short_atomic                             ',&
              nshuffle_weights_short_atomic,shuffle_weights_short_atomic
          endif
        endif
      endif

      if((mode.eq.2).and.lompmkl)then
        write(*,'(a)')' Using omp mkl for Kalman filter in parallel case'
      endif

      if((mode.eq.2).and.lionforcesonly)then
        write(*,'(a)')' Using only forces for fitting in case of ionic structures'
      endif

      if((mode.eq.2).and.lfitstats)then
        write(*,'(a)')' Writing fitting statistics '
      endif

      if((mode.eq.2).and.(restrictw.gt.0.0d0))then
        write(*,'(a,f14.6)')' Restricting absolute value of weights       ',restrictw
        if((restrictw.gt.0.0d0).and.(restrictw.lt.2.0d0))then
          write(*,*)'Currently restrictw must be larger than 2.0'
          stop
        endif
      endif

      if((mode.eq.2).and.lanalyzeerror)then
        write(*,'(a)')' Error analysis requested for final epoch '
        if(lshort.and.(.not.lwritetrainpoints))then
          write(*,*)'WARNING: trainpoints file is required for short range energy error analysis'
          write(*,*)'=> This analysis will not be done'
        endif
        if(lshort.and.luseforces.and.(.not.lwritetrainforces))then
          write(*,*)'WARNING: trainforces file is required for short range force error analysis'
          write(*,*)'=> This analysis will not be done'
        endif
        if(lelec.and.(.not.lwritetraincharges))then
          write(*,*)'WARNING: traincharges file is required for charge error analysis'
          write(*,*)'=> This analysis will not be done'
        endif
      endif
!!
      if(mode.eq.2.and.((luseoldweightsshort).or.(luseoldweightscharge)))then
        write(*,'(a,l)')' Using old scaling data for restart          ',luseoldscaling
      endif
!!
      if((mode.eq.2).and.(lprecond))then
        write(*,*)'Preconditioning of weights is switched on'
      endif
!!
      if((mode.eq.2).and.(linionly))then
        write(*,*)'Termination of mode 2 after initialization requested'
      endif
!!
      if((mode.eq.2).and.(ldataclustering))then
        write(*,'(a,2f14.10)')'data clustering requested with distance thresholds ',&
          dataclusteringthreshold1,dataclusteringthreshold2
      endif
!!
      if((mode.eq.2).and.(lprintconv))then
        write(*,*)'printing of convergence vector requested'
      endif
!!
      if((mode.eq.2).and.(lanalyzecomposition))then
        write(*,*)'analysis of chemical composition requested'
      endif
!!
      if((mode.eq.2).and.lshort)then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'Fitting parameters short range part:'
        write(*,*)'-------------------------------------------------------------'
      endif
!!
      if(lshort.and.(mode.eq.2)) write(*,'(a,l)')' using forces for fitting                                ',luseforces
!!
      if((mode.eq.2).and.lshort)then
        if(optmodee.eq.1)then
          write(*,'(a)')' using Kalman filter optimization (1) for short range energy'
          if(luseedkalman)then
            write(*,'(a)')' using element decoupled Kalman filter'
            if(ledforcesv2)then
              write(*,'(a)')' using second variant of ED force fitting'
            endif
          endif
        elseif(optmodee.eq.2)then
          write(*,'(a)')' using conjugate gradient optimization (2) for short range energy'
        elseif(optmodee.eq.3)then
          write(*,'(a)')' using steepest descent optimization (3) for short range energy'
        else
          write(*,*)'Error: Unknown optimization mode ',optmodee
          stop
        endif
      endif ! mode.eq.2
!!
      if((mode.eq.2).and.lshort.and.luseforces)then
        if(optmodef.eq.1)then
          write(*,'(a)')' using Kalman filter optimization (1) for short range forces'
        elseif(optmodef.eq.2)then
          write(*,'(a)')' using conjugate gradient optimization (2) for short range forces'
        elseif(optmodef.eq.3)then
          write(*,'(a)')' using steepest descent optimization (3) for short range forces'
        else
          write(*,*)'Error: Unknown optimization mode ',optmodef
          stop
        endif
      endif ! mode.eq.2
!!
      if((mode.eq.2).and.lshort.and.(.not.lfixederrore))&
        write(*,'(a,f14.8)')' short energy error threshold                ',kalmanthreshold
!!
      if((mode.eq.2).and.lshort.and.(.not.lfixederrorf))&
        write(*,'(a,f14.8)')' short force error threshold                 ',kalmanthresholdf
!!
      if((mode.eq.2).and.lshort.and.lfixederrore)write(*,'(a,f14.8)')&
        ' fixed short energy error threshold          ',fixederrore
!!
      if((mode.eq.2).and.lshort.and.lfixederrorf)&
        write(*,'(a,f14.8)')' fixed short force error threshold           ',fixederrorf
!!
      if(mode.eq.2)then
        if(lshort.and.(nn_type_short.eq.1))kalmanlambda(:)=kalmanlambda_local
        if(lshort.and.(nn_type_short.eq.2))kalmanlambdap(:)=kalmanlambda_local
      endif
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1))&
        write(*,'(a,f14.8)')' Kalman lambda (short)                       ',kalmanlambda_local
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1))&
        write(*,'(a,f14.8)')' Kalman nue (short)                          ',kalmannue
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1))&
        write(*,'(a,l)')' use_noisematrix                                         ',lusenoisematrix  !! modifed by kenko
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1).and.lusenoisematrix)&
        write(*,'(a,f14.8)')' kalman_q0                                   ',kalman_q0  !! modifed by kenko
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1).and.lusenoisematrix)&
        write(*,'(a,f14.8)')' kalman_qmin                                 ',kalman_qmin  !! modifed by kenko
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1).and.lusenoisematrix)&
        write(*,'(a,f14.8)')' kalman_qtau                                 ',kalman_qtau  !! modifed by kenko
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1).and.lusenoisematrix)&
        write(*,'(a,f14.8)')' kalman_epsilon                              ',kalman_epsilon  !! modifed by kenko
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1))&
        write(*,'(a,f14.8)')' Kalman damp (short energy)                  ',kalman_dampe
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.1))&
        write(*,'(a,f14.8)')' Kalman damp (short force)                   ',kalman_dampf
!!
      if((mode.eq.2).and.lshort.and.(optmodee.eq.3))then
        write(*,'(a,f14.8)')' steepest descent step size short energy     ',steepeststepe
      endif
!!
      if((mode.eq.2).and.lshort.and.(optmodef.eq.3))then
        write(*,'(a,f14.8)')' steepest descent step size short forces     ',steepeststepf
      endif
!!
      if(mode.eq.2)write(*,'(a,l)')' restart fit with old weights (short)                    ',luseoldweightsshort
!!
      if((mode.eq.2).and.lshort.and.luseworste)&
        write(*,'(a,f8.4)')' fraction of worst short range energies            ',worste
!!
      if((mode.eq.2).and.lshort.and.luseforces.and.luseworstf)&
        write(*,'(a,f8.4)')' fraction of worst short range forces              ',worstf
!!
      if((mode.eq.2).and.luseforces.and.lshort)then
        if(scalefactorf.lt.0.0d0)then
          write(*,'(a)')' automatic scaling factor for force update selected'
        else
          write(*,'(a,f11.8)')' scaling factor for force update (scalefactorf) ',scalefactorf
        endif
      endif
!!
      if(lshort.and.(mode.eq.2))&
        write(*,'(a,i8)')' grouping energies in blocks of                    ',nenergygroup
!!
      if(lshort.and.(mode.eq.2)) &
        write(*,'(a,f8.3)')' fraction of energies used for update              ',energyrnd
!!
      if(lshort.and.(mode.eq.2).and.(.not.lfgroupbystruct).and.(luseforces))then
        write(*,'(a,i8)')' grouping forces in blocks of                      ',nforcegroup
      endif
!!
      if(lshort.and.(mode.eq.2).and.(lfgroupbystruct).and.(luseforces))then
        write(*,'(a,i8)')' automatic grouping forces for update by structure'
      endif
!!
      if(lshort.and.(mode.eq.2))write(*,'(a,f8.3)')' fraction of forces used for update                ',forcernd
!!
      if((mode.eq.2).and.lshort.and.(.not.luseoldweightsshort))&
        write(*,'(a,f14.3)')' weights_min                                 ',weights_min
!!
      if((mode.eq.2).and.lshort.and.(.not.luseoldweightsshort))&
        write(*,'(a,f14.3)')' weights_max                                 ',weights_max
!!
      if((mode.eq.2).and.lshort.and.lseparatebiasini.and.(.not.luseoldweightsshort))&
        write(*,'(a,f14.3)')' biasweights_min                             ',biasweights_min
!!
      if((mode.eq.2).and.lshort.and.lseparatebiasini.and.(.not.luseoldweightsshort))&
        write(*,'(a,f14.3)')' biasweights_max                             ',biasweights_max
!!
      if((mode.eq.2).and.lshort.and.lnwweights)write(*,'(a)')' Using Nguyen Widrow weights for short range NN'
!!
      if((mode.eq.2).and.lshort.and.lsysweights)write(*,'(a)')' Using systematic weights for short range NN'
!!
      if((mode.eq.2).and.lelec.and.(nn_type_elec.eq.1).and.lnwweightse)&
        write(*,'(a)')' Using Nguyen Widrow weights for electrostatic NN'
!!
      if((mode.eq.2).and.lelec.and.(nn_type_elec.eq.1).and.lsysweightse)&
        write(*,'(a)')' Using systematic weights for electrostatic NN'
!!
      if((mode.eq.2).and.lshort.and.luseforces.and.lsepkalman.and.(optmodee.eq.1).and.(optmodef.eq.1))then
        write(*,'(a)')' Using separate Kalman filter matrices for short range energies and forces'
      endif
!!
      if((mode.eq.2).and.lshort.and.luseforces.and.lrepeate)then
        write(*,'(a)')' Using repeated energy updates after each force update'
      endif
!!
      if((mode.eq.2).and.lshort.and.(.not.luseforces).and.lfinalforce)then
        write(*,'(a)')' Calculating force error in final epoch only'
      endif
!!
      if((mode.eq.2).and.(lshort))then
        write(*,'(a,f14.3)')' max_energy                                  ',maxenergy
      endif
!!
      if((mode.eq.2).and.(lshort).and.(luseforces))then
        write(*,'(a,f14.3,a)')' max force component used for fitting        ',&
          maxforce,' Ha/Bohr'
      endif
!!
      if((mode.eq.2).and.lshort)then
        write(*,'(a,f14.8,x,a7)')' noise energy threshold                      ',noisee,'Ha/atom'
      endif
!!
      if((mode.eq.2).and.luseforces.and.lshort)then
        write(*,'(a,f14.8,x,a7)')' noise force threshold                       ',noisef,'Ha/Bohr'
      endif
!!
      if((mode.eq.2).and.ldynforcegroup)then
        write(*,'(a,2i8)')' dynamic force grouping                      ',&
          dynforcegroup_start,dynforcegroup_step
      endif
!!
      if((mode.eq.2).and.ldetect_saturation.and.(lshort).and.(nn_type_short.eq.1))then
        write(*,'(a,f14.6)')' detect saturation of nodes is on            ',&
          saturation_threshold
      endif
!!
      if((mode.eq.2).and.lelec)then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'Fitting parameters electrostatic part:'
        write(*,*)'-------------------------------------------------------------'
      endif






      if(mode.eq.3)then
        write(*,*)'-------------------------------------------------------------'
        write(*,*)'Options for prediction mode:'
        write(*,*)'-------------------------------------------------------------'
      endif

      if(mode.eq.3)write(*,'(a,l)')' rescale symmetry functions                              ',lscalesym

      if(mode.eq.3)write(*,'(a,l)')' remove CMS from symmetry functions                      ',lcentersym

      if(mode.eq.3)then
        if(lreadunformatted)then
          write(*,'(a)')' Reading unformatted files '
        else
          write(*,'(a)')' Reading formatted files '
        endif
      endif

      if(mode.eq.3)&
        write(*,'(a,l)')' calculation of analytic forces                          ',ldoforces

      if(mode.eq.3)&
        write(*,'(a,l)')' calculation of analytic Hessian                         ',ldohessian

      if(mode.eq.3)&
        write(*,'(a,l)')' calculation of analytic stress                          ',ldostress

      if((mode.eq.3).and.ldohessian)&
        write(*,'(a,l)')' calculation of analytic hessian                         ',ldohessian

      if(mode.eq.3)&
        write(*,'(a,l)')' write symmetry functions                                ',lwritesymfunctions

      if((mode.eq.3).and.lsens    )write(*,'(a,l)')' calculation of NN sensitivity                           ',lsens

      if(mode.eq.3)write(*,'(a,l)')' prepare md                                              ',lpreparemd

      write(*,*)'============================================================='





    end subroutine printinputnn

    subroutine readscale(filename,filename_error,ndim,iswitch,maxnum_funcvalues_local,num_funcvalues_local,minvalue_local,maxvalue_local,avvalue_local,eshortmin,eshortmax,chargemin,chargemax)

        implicit none

        integer             :: scaling_unit
        integer             :: ndim
        integer             :: maxnum_funcvalues_local
        integer             :: num_funcvalues_local(ndim)
        integer             :: counter_1, counter_2, counter_3
        integer             :: iswitch

        real(dp)            :: avvalue_local(ndim,maxnum_funcvalues_local)
        real(dp)            :: maxvalue_local(ndim,maxnum_funcvalues_local)
        real(dp)            :: minvalue_local(ndim,maxnum_funcvalues_local)
        real(dp)            :: thres
        real(dp)            :: eshortmin
        real(dp)            :: eshortmax
        real(dp)            :: chargemin(nelem)
        real(dp)            :: chargemax(nelem)

        logical             :: lexist

        character(len=*)                    :: err = "Error in readscale: "

        character(len=max_string_length)    :: filename
        character(len=*)                    :: filename_error

        integer, parameter  :: scaling_unit = 62 ! for scling.data and scalinge.data



        thres=0.00001d0

        call open_for_read(scaling_unit, filename); ios = 0

        do counter_1 = 1,ndim
            do counter_2 = 1,num_funcvalues_local(counter_1)
                read(scaling_unit, '(A)', iostat=ios) buffer
                line = line + 1

                if (ios == 0) then
                    call split_string(buffer, words, nwords)

                    if (nwords == 5) then
                        read(words(1),'(i1000)', iostat=ios) counter_3
                        if (ios /= 0) stop err // err_inpnn // "Error in line ", line, ", first argument value must be integer"
                        read(words(2),'(i1000)', iostat=ios) counter_3
                        if (ios /= 0) stop err // err_inpnn // "Error in line ", line, ", second argument value must be integer"
                        read(words(3),*, iostat=ios) minvalue_local(counter_1,counter_2)
                        if (ios /= 0) stop err // err_inpnn // "Error in line ", line, ", third argument value must be a number"
                        read(words(4),*, iostat=ios) maxvalue_local(counter_1,counter_2)
                        if (ios /= 0) stop err // err_inpnn // "Error in line ", line, ", fourth argument value must be a number"
                        read(words(5),*, iostat=ios) avvalue_local(counter_1,counter_2)
                        if (ios /= 0) stop err // err_inpnn // "Error in line ", line, ", fifth argument value must be a number"
                    else
                        print *, err, filename_error, "Error in line: ", line, "; need exactly 5 arguments"
                        stop
                    end if
                else
                    print *, err // filename_error // 'iostat = ', ios
                    stop
                end if

            end do
        end do

        read(scaling_unit, '(A)', iostat=ios) buffer

        if (ios == 0) then
            call split_string(buffer, words, nwords)

            if (iswitch == 1) then
                if (nwords == 2) then
                    read(words(1),*, iostat=ios) eshortmin
                    if (ios /= 0) stop err // err_inpnn // "Error in last line: " // "first argument value must be a number"
                    read(words(2),*, iostat=ios) eshortmax
                    if (ios /= 0) stop err // err_inpnn // "Error in last line: " // "second argument value must be a number"
                else
                    print *, err, filename_error, "Error in last line: need exactly 2 arguments"
                    stop
                end if
            else if (iswitch == 3) ! 3 to be comparable to RuNNer
                do counter_2 = 1,nelem
                    line = line + 1
                    if (nwords == 2) then
                        read(words(1),*, iostat=ios) chargemin(counter_2)
                        if (ios /= 0) stop err // err_inpnn // "Error in line: " // line // ", first argument value must be a number"
                        read(words(2),*, iostat=ios) chargemax(counter_2)
                        if (ios /= 0) stop err // err_inpnn // "Error in line: " // line // ", second argument value must be a number"
                    else
                        print *, err, filename_error, "Error in line: ", line, " need exactly 2 arguments"
                        stop
                    end if
                end do
            end if
        else
            write(*,*) err // filename_error // 'iostat = ', ios
            stop
        end if

        close(scaling_unit)

        do counter_1 = 1,ndim
            do counter_3 = 1,num_funcvalues_local(counter_1)
                if (minvalue_local(counter_1,counter_3) .gt. maxvalue_local(counter_1,counter_3)) then
                    print *, err // filename_error // 'No pairs of this type have been present in training set'
                else
                    if (abs(minvalue_local(counter_1,counter_3) - maxvalue_local(counter_1,counter_3)) .lt. thres) then
                        if (iswitch == 1) then
                            print *, err // filename_error // '### WARNING ###: minvalue=maxvalue ',counter_1,counter_3,nucelem(counter_1)
                        else if (iswitch == 3) then
                            print *, err // filename_error // '### WARNING ###: minvalue_elec=maxvalue_elec ',counter_1,counter_3,nucelem(counter_1)
                        end if
                        if (lscalesym) then
                            if (iswitch == 1) then
                                print *, err // filename_error // 'scaling symmetry functions cannot be used with minvalue=maxvalue'
                                stop
                            else if (iswitch == 3) then
                                print *, err // filename_error // 'scaling symmetry functions cannot be used with minvalue_elec=maxvalue_elec'
                                stop
                            end if
                        end if
                    end if
                end if
            end do
        end do

    end subroutine readscale

    subroutine readweights(directory,iswitch,ndim,maxnum_weights_local,num_weights_local,weights_local)

        implicit none

        integer             :: ndim
        integer             :: iswitch
        integer             :: icount
        integer             :: maxnum_weights_local
        integer             :: num_weights_local(ndim)
        integer             :: counter_1, counter_2, counter_3, counter_4

        real(dp)            :: weights_local(maxnum_weights_local,ndim)

        logical             :: lexist

        character(len=*)                    :: err = "Error in readweights: "
        character(len=*)                    :: err_weight = "Error when reading the following weight file: "
        character(len=*)                    :: err_weighte = "Error when reading the following weighte file: "

        character(len=max_string_length)    :: directory, filename_weight, filename_weighte
        character*40                        :: filename

        integer, parameter  :: weight_unit  = 64
        integer, parameter  :: weighte_unit = 65

        if (iswitch == 0) then
            do counter_1 = 1,ndim
                filename = 'weights.000.data'
                if (nucelem(counter_1) .gt. 99) then
                    write(filename(9:11),'(i3)') nucelem(counter_1)
                else if (nucelem(counter_1) .gt. 9) then
                    write(filename(10:11),'(i2)') nucelem(counter_1)
                else
                    write(filename(11:11),'(i1)') nucelem(counter_1)
                end if
                filename_weight = trim(directory) // trim(filename)
                if (.not. file_exists(filename_weight)) stop err // err_weight // trim(filename) // 'file does not exist'

                call open_for_read(weight_unit, filename_weight); ios = 0

                do counter_2 = 1,num_weights_local(counter_1)
                    read(weight_unit, '(A)', iostat=ios) buffer
                    line = line + 1

                    if (ios == 0) then
                        call split_string(buffer, words, nwords)

                        if (nwords == 1) then
                            read(words(1),*, iostat=ios) weights_local(counter_2,counter_1)
                            if (ios /= 0) stop err // err_weight // trim(filename) // "Error in line ", line, ", first argument value must be a number"
                        else
                            print *, err, err_weight, trim(filename), "Error in line ", line, "need exactly 1 argument"
                            stop
                        end if
                    else
                         write(*,*) err // err_weight // trim(filename) // 'iostat = ', ios
                         stop
                    end if
                end do

                close(weight_unit)

            end do
        else if (iswitch == 1) then
            do counter_1 = 1,ndim
                filename = 'weightse.000.data'
                if (nucelem(counter_1) .gt. 99) then
                    write(filename(9:11),'(i3)') nucelem(counter_1)
                else if (nucelem(counter_1) .gt. 9) then
                    write(filename(10:11),'(i2)') nucelem(counter_1)
                else
                    write(filename(11:11),'(i1)') nucelem(counter_1)
                end if
                filename_weighte = trim(directory) // trim(filename)
                if (.not. file_exists(filename_weighte)) stop err // err_weighte // trim(filename) // 'file does not exist'

                call open_for_read(weighte_unit, filename_weighte); ios = 0

                do counter_2 = 1,num_weights_local(counter_1)
                    read(weighte_unit, '(A)', iostat=ios) buffer
                    line = line + 1

                    if (ios == 0) then
                        call split_string(buffer, words, nwords)

                        if (nwords == 1) then
                            read(words(1),*, iostat=ios) weights_local(counter_2,counter_1)
                            if (ios /= 0) stop err // err_weighte // trim(filename) // "Error in line ", line, ", first argument value must be a number"
                        else
                            print *, err, err_weighte, trim(filename), "Error in line ", line, "need exactly 1 argument"
                            stop
                        end if
                    else
                         write(*,*) err // err_weighte // trim(filename) // 'iostat = ', ios
                         stop
                    end if
                end do

                close(weighte_unit)

            end do
        else
            write(*,*) err // "Error: unknown iswitch value ", iswitch
            stop
        end if

    end subroutine readweights

    subroutine cleanup()

            implicit none

            ! according to compute_nene (based on predict.f90)
            if(lshort.and.(nn_type_short.eq.1))then
                    deallocate(sens)
            end if

            if(lelec.and.(nn_type_elec.eq.1).or.(nn_type_elec.eq.3).or.(nn_type_elec.eq.4))then
                    deallocate(sense)
            end if

            ! according to cleanup.f90
            if(lshort.and.(nn_type_short.eq.1))then
                    deallocate(weights_short_atomic)
                    deallocate(symfunction_short_atomic_list)
                    deallocate(num_funcvalues_short_atomic)
                    deallocate(windex_short_atomic)
                    deallocate(num_layers_short_atomic)
                    deallocate(actfunc_short_atomic)
                    deallocate(nodes_short_atomic)
                    deallocate(num_weights_short_atomic)
                    deallocate(function_type_short_atomic)
                    deallocate(symelement_short_atomic)
                    deallocate(funccutoff_short_atomic)
                    deallocate(eta_short_atomic)
                    deallocate(zeta_short_atomic)
                    deallocate(lambda_short_atomic)
                    deallocate(rshift_short_atomic)
            endif

            if(lelec.and.(nn_type_elec.eq.1))then
                    deallocate(weights_elec)
                    deallocate(symfunction_elec_list)
                    deallocate(num_funcvalues_elec)
                    deallocate(windex_elec)
                    deallocate(num_layers_elec)
                    deallocate(actfunc_elec)
                    deallocate(nodes_elec)
                    deallocate(num_weights_elec)
                    deallocate(function_type_elec)
                    deallocate(symelement_elec)
                    deallocate(funccutoff_elec)
                    deallocate(eta_elec)
                    deallocate(zeta_elec)
                    deallocate(lambda_elec)
                    deallocate(rshift_elec)
            endif

            deallocate(nucelem)
            deallocate(element)
            deallocate(dmin_element)
            if(allocated(atomrefenergies))deallocate(atomrefenergies)
            if(allocated(fixedcharge))deallocate(fixedcharge)
            if(allocated(elempair))deallocate(elempair)

            call mpi_barrier(mpi_comm_world,mpierror)

            ! according to main.f90
            call mpi_finalize(mpierror)

    end subroutine cleanup

    subroutine compute_nene(atoms, flag)

        ! Calculates energy and forces with HDNNPs

        ! md_tian2 related modules
        use constants, only : habohr2evang, timestep_ha2ev => ha2ev ! think about better way to realize that here we need our more precise ha2ev variable!!; conflict due to ha2ev from nnconstants.f90 and constants.f90




        type(universe), intent(inout)   :: atoms
        integer, intent(in)             :: flag

        character(len=*), parameter :: err = "Error in compute_nene: "

        ! 2do in compute_nene:
        ! the elements have to be sorted according to RuNNer before calling the prediction -> better way than calling sortelements in every MD step -> do that once in read_nene subroutine
        ! convert the lattice just once in read_nene and not in every MD step
        ! print symmetry function values, volume, NN sum, atomic energies, atomic forces only if keyword is given (true, detailed_information or so) every MD step, default is false and only warnings should be printed!
        ! introduce logic variable for writing information like volume etc.
        ! include the cleanup function in the md_tian2 source code after the loop over trajectories
        ! compare initnn and initmode3!!


        !call getstructure_mode3(i4,num_atoms,num_pairs,zelem,num_atoms_element,lattice,xyzstruct,totalenergy,totalcharge,totalforce,atomenergy,atomcharge,elementsymbol,lperiodic)

        ! start according to getstructure_mode3.f90

        ! convert position units, commit element symbols and set corresponding RuNNer variables
        do j = 1,atoms%natoms
            xyzstruct(:,j) = atoms%r(:,:,j) * ang2bohr
            elementsymbol(j) = atoms%name(atoms%idx(j))
            call nuccharge(elementsymbol(j),zelem(j))
            lelement(zelem(j)) = .true.
        end do
        ! end according to getstructure_mode3.f90


        ! the initialization of mode3 will be done in read_nene
        ! start according to initmode3.f90

        !call initmode3(i4,minvalue_short_atomic,maxvalue_short_atomic,avvalue_short_atomic,minvalue_short_pair,maxvalue_short_pair,avvalue_short_pair,minvalue_elec,maxvalue_elec,avvalue_elec,eshortmin,eshortmax,chargemin,chargemax)

        ! end according to initmode3.f90

        ! further according to predict.f90

        if(lshort .and. nn_type_short == 1) then
            call predictionshortatomic(&
              num_atoms,num_atoms_element,zelem,&
              lattice,xyzstruct,&
              minvalue_short_atomic,maxvalue_short_atomic,avvalue_short_atomic,&
              eshortmin,eshortmax,&
              nntotalenergy,nnshortforce,&
              nnatomenergy,nnshortenergy,nnstress_short,&
              atomenergysum,sens,lperiodic)
        endif

        if(lelec .and. ((nn_type_elec == 1) .or. (nn_type_elec == 3) .or. (nn_type_elec == 4))) then
            print *, err, "electrostatic NN prediction not implemented"; stop
          !call predictionelectrostatic(&
            !num_atoms,zelem,&
            !minvalue_elec,maxvalue_elec,avvalue_elec,&
            !lattice,xyzstruct,&
            !nntotalcharge,nnatomcharge,&
            !chargemin,chargemax,nnelecenergy,&
            !nnelecforce,nnstress_elec,sense,lperiodic)
        else
          nnatomcharge(:)=0.0d0
        endif

        ! combine short range and electrostatic energies
        nntotalenergy=nnshortenergy+nnelecenergy

        ! add energies of free atoms
        if(lremoveatomenergies.and.lshort)then
          call addatoms(num_atoms,&
            zelem,num_atoms_element,&
            atomenergysum,nnatomenergy)
          nntotalenergy=nntotalenergy+atomenergysum
        endif

        ! convert calculated energy from RuNNer to MDT2
        atoms%epot = nntotalenergy * timestep_ha2ev


        ! combination of short-range and electrostatic forces
        if(ldoforces)then
          nntotalforce(:,:)=nnshortforce(:,:)+nnelecforce(:,:)
        endif

        ! convert calculated forces from RuNNer to MDT2
        atoms%f(:,:,:) = nntotalforce(:,:) * habohr2evang

        ! calculate the volume, needed also for stress
        if(lperiodic)then
          volume=0.0d0
          call getvolume(lattice,volume)
          if((mpirank.eq.0).and.(.not.lmd))then
            write(*,*)'-------------------------------------------------------------'
            write(*,*)'volume ',volume,' Bohr^3 for configuration ', i4
          endif
        endif

        ! combination of short-range and electrostatic stress
        if(ldostress.and.lperiodic)then
          nnstress(:,:)=nnstress_short(:,:)+nnstress_elec(:,:)
          nnstress(:,:)=nnstress(:,:)/volume
        endif

        ! check sum of forces if requested -> do we need that? seems fine, but clarify
        if(lcheckf)then
            forcesum(:)=0.0d0 ! convert to our unit convention!!
            do i3=1,num_atoms
                do i2=1,3
                    forcesum(i2)=forcesum(i2)+nntotalforce(i2,i3)
                enddo ! i2
            enddo ! i3
            write(*,'(A10,3A25)')'Conf.','Sum of Fx(Ha/Bohr)', 'Sum of Fy(Ha/Bohr)','Sum of Fz(Ha/Bohr)'
            write(*,'(I10,3f25.8)')i1,forcesum(1),forcesum(2),forcesum(3)
            do i2=1,3
                if(abs(forcesum(i2)).gt.0.000001d0)then
                    write(*,'(I10,A31,I10,f25.8)')i4,'Error in forces of component: ',&
                        i2,forcesum(i2)
                    stop
                endif
            enddo ! i2
        endif

        !if(lshort.and.(nn_type_short.eq.1))then ! -> this should move to cleanup subroutine
        !    deallocate(sens)
        !endif
        !if(lelec.and.(nn_type_elec.eq.1).or.(nn_type_elec.eq.3).or.(nn_type_elec.eq.4))then ! -> this should move to cleanup subroutine
        !    deallocate(sense)
        !endif
        ! end according to predict.f90

    end subroutine compute_nene

end module pes_nene_mod

subroutine set_defaults()

        iseed                               = default_int
        ielem                               = default_int
        lelement                            = default_bool

        nn_type_short                       = default_int
        mode                                = default_int
        lshort                              = default_bool
        lelec                               = default_bool
        nn_type_elec                        = default_int
        lfounddebug                         = default_bool
        ldebug                              = default_bool
        lfound_num_layersshort              = default_bool
        maxnum_layers_short_atomic          = default_int
        lfound_num_layersewald              = default_bool
        maxnum_layers_elec                  = default_int
        lfound_luseatomenergies             = default_bool
        luseatomenergies                    = default_bool
        lfound_luseatomcharges              = default_bool
        luseatomcharges                     = default_bool
        lfound_nelem                        = default_bool
        nelem                               = default_int
        npairs                              = default_int
        max_num_pairs                       = default_int
        element                             = default_string
        nucelem                             = default_int
        dmin_element                        = default_real
        !nodes_short_local                   = default_int
        !nodes_ewald_local                   = default_int
        !num_funcvalues_local                = 0 ! needed so that the max function will work
        !num_funcvaluese_local               = 0 ! needed so that the max function will work
        elementtemp                         = default_string
        ztemp                               = default_int
        maxnum_funcvalues_short_atomic      = 0 ! needed so that the max function will work
        maxnum_funcvalues_elec              = 0 ! needed so that the max function will work
        function_type_local                 = default_int
        function_type_temp                  = default_int
        funccutoff_local                    = 0.0d0 ! needed so that the max function will work
        maxcutoff_local                     = 0.0d0 ! needed so that the max function will work
        elementtemp1                        = default_string
        elementtemp2                        = default_string
        elementtemp3                        = default_string

        maxnodes_short_atomic               = 0 ! needed so that the max function will work
        maxnodes_elec                       = 0 ! needed so that the max function will work

        lperiodic                           = .true. ! no default_bool, because we ALWAYS assume a periodic structure!






        pstring = default_string

        ldebug = default_bool
        !maxnum_layers_short_atomic = default_int
        luseatomenergies = default_bool
        luseatomcharges = default_bool


    end subroutine set_defaults
