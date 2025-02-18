! Copyright 2019 NREL

! Licensed under the Apache License, Version 2.0 (the "License"); you may not use
! this file except in compliance with the License. You may obtain a copy of the
! License at http://www.apache.org/licenses/LICENSE-2.0

! Unless required by applicable law or agreed to in writing, software distributed
! under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
! CONDITIONS OF ANY KIND, either express or implied. See the License for the
! specific language governing permissions and limitations under the License.
! -------------------------------------------------------------------------------------------

! This module contains the primary controller routines

MODULE Controllers

    USE, INTRINSIC :: ISO_C_Binding
    USE Functions
    USE Filters
    USE ControllerBlocks

    IMPLICIT NONE

CONTAINS
!-------------------------------------------------------------------------------------------------------------------------------
    SUBROUTINE PitchControl(avrSWAP, CntrPar, LocalVar, objInst, DebugVar, ErrVar)
    ! Blade pitch controller, generally maximizes rotor speed below rated (region 2) and regulates rotor speed above rated (region 3)
    !       PC_State = 0, fix blade pitch to fine pitch angle (PC_FinePit)
    !       PC_State = 1, is gain scheduled PI controller 
        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables, ObjectInstances, DebugVariables, ErrorVariables
        
        ! Inputs
        REAL(ReKi),              INTENT(INOUT)       :: avrSWAP(*)   ! The swap array, used to pass data to, and receive data from the DLL controller.
        TYPE(ControlParameters),    INTENT(INOUT)       :: CntrPar
        TYPE(LocalVariables),       INTENT(INOUT)       :: LocalVar
        TYPE(ObjectInstances),      INTENT(INOUT)       :: objInst
        TYPE(DebugVariables),       INTENT(INOUT)       :: DebugVar
        TYPE(ErrorVariables),       INTENT(INOUT)       :: ErrVar

        ! Allocate Variables:
        INTEGER(IntKi)                                  :: K            ! Index used for looping through blades.

        CHARACTER(*),               PARAMETER           :: RoutineName = 'PitchControl'

        ! ------- Blade Pitch Controller --------
        ! Load PC State
        IF (LocalVar%PC_State == 1) THEN ! PI BldPitch control
            LocalVar%PC_MaxPit = CntrPar%PC_MaxPit
        ELSE ! debug mode, fix at fine pitch
            LocalVar%PC_MaxPit = CntrPar%PC_FinePit
        END IF
        
        ! Compute (interpolate) the gains based on previously commanded blade pitch angles and lookup table:
        LocalVar%PC_KP = interp1d(CntrPar%PC_GS_angles, CntrPar%PC_GS_KP, LocalVar%PC_PitComTF, ErrVar) ! Proportional gain
        LocalVar%PC_KI = interp1d(CntrPar%PC_GS_angles, CntrPar%PC_GS_KI, LocalVar%PC_PitComTF, ErrVar) ! Integral gain
        LocalVar%PC_KD = interp1d(CntrPar%PC_GS_angles, CntrPar%PC_GS_KD, LocalVar%PC_PitComTF, ErrVar) ! Derivative gain
        LocalVar%PC_TF = interp1d(CntrPar%PC_GS_angles, CntrPar%PC_GS_TF, LocalVar%PC_PitComTF, ErrVar) ! TF gains (derivative filter) !NJA - need to clarify
        
        ! Find Power Tracking Control contribution
        IF (CntrPar%PTC_ControlMode>=1) THEN 
            CALL PTC_bladePitch(CntrPar,LocalVar)
            !Update the LocalVar%PC_SpdErr for the PIController
        END IF

        ! Compute the collective pitch command associated with the proportional and integral gains:
        LocalVar%PC_PitComT = PIController(LocalVar%PC_SpdErr, LocalVar%PC_KP, LocalVar%PC_KI, LocalVar%PC_MinPit, LocalVar%PC_MaxPit, LocalVar%DT, LocalVar%BlPitch(1), LocalVar%piP, LocalVar%restart, objInst%instPI)
        DebugVar%PC_PICommand = LocalVar%PC_PitComT
        ! Find individual pitch control contribution
        IF ((CntrPar%IPC_ControlMode >= 1) .OR. (CntrPar%Y_ControlMode == 2)) THEN
            CALL IPC(CntrPar, LocalVar, objInst, DebugVar)
        ELSE
            LocalVar%IPC_PitComF = 0.0 ! THIS IS AN ARRAY!!
        END IF
        
        ! Include tower fore-aft tower vibration damping control
        IF ((CntrPar%FA_KI > 0.0) .OR. (CntrPar%Y_ControlMode == 2)) THEN
            CALL ForeAftDamping(CntrPar, LocalVar, objInst)
        ELSE
            LocalVar%FA_PitCom = 0.0 ! THIS IS AN ARRAY!!
        ENDIF
        
        ! Pitch Saturation
        IF (CntrPar%PS_Mode > 0) THEN
            LocalVar%PC_MinPit = PitchSaturation(LocalVar,CntrPar,objInst,DebugVar, ErrVar)
            LocalVar%PC_MinPit = max(LocalVar%PC_MinPit, CntrPar%PC_FinePit)
        ELSE
            LocalVar%PC_MinPit = CntrPar%PC_FinePit
        ENDIF
        DebugVar%PC_MinPit = LocalVar%PC_MinPit
        
        ! FloatingFeedback
        IF (CntrPar%Fl_Mode > 0) THEN
            LocalVar%Fl_PitCom = FloatingFeedback(LocalVar, CntrPar, objInst)
            DebugVar%FL_PitCom = LocalVar%Fl_PitCom
            LocalVar%PC_PitComT = LocalVar%PC_PitComT + LocalVar%Fl_PitCom
        ENDIF
        
        ! Shutdown
        IF (CntrPar%SD_Mode == 1) THEN
            LocalVar%PC_PitComT = Shutdown(LocalVar, CntrPar, objInst)
        ENDIF
        
        ! Saturate collective pitch commands:
        LocalVar%PC_PitComT = saturate(LocalVar%PC_PitComT, LocalVar%PC_MinPit, CntrPar%PC_MaxPit)                    ! Saturate the overall command using the pitch angle limits
        LocalVar%PC_PitComT = ratelimit(LocalVar%PC_PitComT, LocalVar%PC_PitComT_Last, CntrPar%PC_MinRat, CntrPar%PC_MaxRat, LocalVar%DT) ! Saturate the overall command of blade K using the pitch rate limit
        LocalVar%PC_PitComT_Last = LocalVar%PC_PitComT

        ! Combine and saturate all individual pitch commands:
        ! Filter to emulate pitch actuator
        DO K = 1,LocalVar%NumBl ! Loop through all blades, add IPC contribution and limit pitch rate
            LocalVar%PitCom(K) = LocalVar%PC_PitComT + LocalVar%FA_PitCom(K) 
            LocalVar%PitCom(K) = saturate(LocalVar%PitCom(K), LocalVar%PC_MinPit, CntrPar%PC_MaxPit)                    ! Saturate the command using the pitch satauration limits
            LocalVar%PitCom(K) = LocalVar%PC_PitComT + LocalVar%IPC_PitComF(K)                                          ! Add IPC
            LocalVar%PitCom(K) = saturate(LocalVar%PitCom(K), LocalVar%PC_MinPit, CntrPar%PC_MaxPit)                    ! Saturate the command using the absolute pitch angle limits
            LocalVar%PitCom(K) = ratelimit(LocalVar%PitCom(K), LocalVar%BlPitch(K), CntrPar%PC_MinRat, CntrPar%PC_MaxRat, LocalVar%DT) ! Saturate the overall command of blade K using the pitch rate limit
        END DO

        ! Open Loop control, use if
        !   Open loop mode active         Using OL blade pitch control      
        IF ((CntrPar%OL_Mode == 1) .AND. (CntrPar%Ind_BldPitch > 0)) THEN
            IF (LocalVar%Time >= CntrPar%OL_Breakpoints(1)) THEN    ! Time > first open loop breakpoint
                DO K = 1,LocalVar%NumBl ! Loop through all blades
                    LocalVar%PitCom(K) = interp1d(CntrPar%OL_Breakpoints,CntrPar%OL_BldPitch,LocalVar%Time, ErrVar)
                END DO
            ENDIF
        ENDIF

        ! Command the pitch demanded from the last
        ! call to the controller (See Appendix A of Bladed User's Guide):
        avrSWAP(42) = LocalVar%PitCom(1)    ! Use the command angles of all blades if using individual pitch
        avrSWAP(43) = LocalVar%PitCom(2)    ! "
        avrSWAP(44) = LocalVar%PitCom(3)    ! "
        avrSWAP(45) = LocalVar%PitCom(1)    ! Use the command angle of blade 1 if using collective pitch

        ! Add RoutineName to error message
        IF (ErrVar%aviFAIL < 0) THEN
            ErrVar%ErrMsg = RoutineName//':'//TRIM(ErrVar%ErrMsg)
        ENDIF

    END SUBROUTINE PitchControl
!-------------------------------------------------------------------------------------------------------------------------------  
    SUBROUTINE VariableSpeedControl(avrSWAP, CntrPar, LocalVar, objInst, ErrVar)
    ! Generator torque controller
    !       VS_State = 0, Error state, for debugging purposes, GenTq = VS_RtTq
    !       VS_State = 1, Region 1(.5) operation, torque control to keep the rotor at cut-in speed towards the Cp-max operational curve
    !       VS_State = 2, Region 2 operation, maximum rotor power efficiency (Cp-max) tracking using K*omega^2 law, fixed fine-pitch angle in BldPitch controller
    !       VS_State = 3, Region 2.5, transition between below and above-rated operating conditions (near-rated region) using PI torque control
    !       VS_State = 4, above-rated operation using pitch control (constant torque mode)
    !       VS_State = 5, above-rated operation using pitch and torque control (constant power mode)
    !       VS_State = 6, Tip-Speed-Ratio tracking PI controller
        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables, ObjectInstances, ErrorVariables
        ! Inputs
        REAL(ReKi),                 INTENT(INOUT)       :: avrSWAP(*)    ! The swap array, used to pass data to, and receive data from, the DLL controller.
        TYPE(ControlParameters),    INTENT(INOUT)       :: CntrPar
        TYPE(LocalVariables),       INTENT(INOUT)       :: LocalVar
        TYPE(ObjectInstances),      INTENT(INOUT)       :: objInst
        TYPE(ErrorVariables),       INTENT(INOUT)       :: ErrVar

        CHARACTER(*),               PARAMETER           :: RoutineName = 'VariableSpeedControl'


        ! Allocate Variables
        
        ! -------- Variable-Speed Torque Controller --------
        ! Define max torque
        IF (LocalVar%VS_State == 4) THEN
           LocalVar%VS_MaxTq = CntrPar%VS_RtTq
        ELSE
            ! VS_MaxTq = CntrPar%VS_MaxTq           ! NJA: May want to boost max torque
            LocalVar%VS_MaxTq = CntrPar%VS_RtTq
        ENDIF

        ! Optimal Tip-Speed-Ratio tracking controller
        IF ((CntrPar%VS_ControlMode == 2) .OR. (CntrPar%VS_ControlMode == 3)) THEN
            ! Constant Power, update VS_MaxTq
            IF (CntrPar%VS_ControlMode == 3) THEN
                LocalVar%VS_MaxTq = min((CntrPar%VS_RtPwr/(CntrPar%VS_GenEff/100.0))/LocalVar%GenSpeedF, CntrPar%VS_MaxTq)
            END IF

            ! PI controller
            LocalVar%GenTq = PIController(LocalVar%VS_SpdErr, CntrPar%VS_KP(1), CntrPar%VS_KI(1), CntrPar%VS_MinTq, LocalVar%VS_MaxTq, LocalVar%DT, LocalVar%VS_LastGenTrq, LocalVar%piP, LocalVar%restart, objInst%instPI)
            LocalVar%GenTq = saturate(LocalVar%GenTq, CntrPar%VS_MinTq, LocalVar%VS_MaxTq)
           
        ! K*Omega^2 control law with PI torque control in transition regions
        ELSE
            ! Update PI loops for region 1.5 and 2.5 PI control
            LocalVar%GenArTq = PIController(LocalVar%VS_SpdErrAr, CntrPar%VS_KP(1), CntrPar%VS_KI(1), CntrPar%VS_MaxOMTq, CntrPar%VS_ArSatTq, LocalVar%DT, CntrPar%VS_MaxOMTq, LocalVar%piP, LocalVar%restart, objInst%instPI)
            LocalVar%GenBrTq = PIController(LocalVar%VS_SpdErrBr, CntrPar%VS_KP(1), CntrPar%VS_KI(1), CntrPar%VS_MinTq, CntrPar%VS_MinOMTq, LocalVar%DT, CntrPar%VS_MinOMTq, LocalVar%piP, LocalVar%restart, objInst%instPI)
            
            ! The action
            IF (LocalVar%VS_State == 1) THEN ! Region 1.5
                LocalVar%GenTq = LocalVar%GenBrTq
            ELSEIF (LocalVar%VS_State == 2) THEN ! Region 2
                LocalVar%GenTq = CntrPar%VS_Rgn2K*LocalVar%GenSpeedF*LocalVar%GenSpeedF
            ELSEIF (LocalVar%VS_State == 3) THEN ! Region 2.5
                LocalVar%GenTq = LocalVar%GenArTq
            ELSEIF (LocalVar%VS_State == 4) THEN ! Region 3, constant torque
                LocalVar%GenTq = CntrPar%VS_RtTq
            ELSEIF (LocalVar%VS_State == 5) THEN ! Region 3, constant power
                LocalVar%GenTq = (CntrPar%VS_RtPwr/(CntrPar%VS_GenEff/100.0))/LocalVar%GenSpeedF
            END IF
            
            ! Saturate
            LocalVar%GenTq = saturate(LocalVar%GenTq, CntrPar%VS_MinTq, CntrPar%VS_MaxTq)
        ENDIF

        ! Find Power Tracking Control contribution
        IF (CntrPar%PTC_ControlMode>=1) THEN 
            CALL PTC_genTorque(CntrPar,LocalVar,ErrVar)
            !Update the LocalVar%GenTq
        END IF

        ! Saturate the commanded torque using the maximum torque limit:
        LocalVar%GenTq = MIN(LocalVar%GenTq, CntrPar%VS_MaxTq)                    ! Saturate the command using the maximum torque limit
        
        ! Saturate the commanded torque using the torque rate limit:
        LocalVar%GenTq = ratelimit(LocalVar%GenTq, LocalVar%VS_LastGenTrq, -CntrPar%VS_MaxRat, CntrPar%VS_MaxRat, LocalVar%DT)    ! Saturate the command using the torque rate limit
        
        ! Open loop torque control
        IF ((CntrPar%OL_Mode == 1) .AND. (CntrPar%Ind_GenTq > 0)) THEN
            IF (LocalVar%Time >= CntrPar%OL_Breakpoints(1)) THEN
                LocalVar%GenTq = interp1d(CntrPar%OL_Breakpoints,CntrPar%OL_GenTq,LocalVar%Time,ErrVar)
            ENDIF
        ENDIF

        ! Reset the value of LocalVar%VS_LastGenTrq to the current values:
        LocalVar%VS_LastGenTrq = LocalVar%GenTq
        LocalVar%VS_LastGenPwr = LocalVar%VS_GenPwr
        
        ! Set the command generator torque (See Appendix A of Bladed User's Guide):
        avrSWAP(47) = MAX(0.0_DbKi, LocalVar%VS_LastGenTrq)  ! Demanded generator torque, prevent negatives.

        ! Add RoutineName to error message
        IF (ErrVar%aviFAIL < 0) THEN
            ErrVar%ErrMsg = RoutineName//':'//TRIM(ErrVar%ErrMsg)
        ENDIF

    END SUBROUTINE VariableSpeedControl
!-------------------------------------------------------------------------------------------------------------------------------
    SUBROUTINE YawRateControl(avrSWAP, CntrPar, LocalVar, objInst, ErrVar)
        ! Yaw rate controller
        !       Y_ControlMode = 0, No yaw control
        !       Y_ControlMode = 1, Simple yaw rate control using yaw drive
        !       Y_ControlMode = 2, Yaw by IPC (accounted for in IPC subroutine)
        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables, ObjectInstances, ErrorVariables
    
        REAL(ReKi),                 INTENT(INOUT)       :: avrSWAP(*) ! The swap array, used to pass data to, and receive data from, the DLL controller.
        TYPE(ControlParameters),    INTENT(INOUT)       :: CntrPar
        TYPE(LocalVariables),       INTENT(INOUT)       :: LocalVar
        TYPE(ObjectInstances),      INTENT(INOUT)       :: objInst
        TYPE(ErrorVariables),       INTENT(INOUT)       :: ErrVar

        CHARACTER(*),               PARAMETER           :: RoutineName = 'YawRateControl'

        
        !..............................................................................................................................
        ! Yaw control
        !..............................................................................................................................
        
        IF (CntrPar%Y_ControlMode == 1) THEN
            avrSWAP(29) = 0                                      ! Yaw control parameter: 0 = yaw rate control
            IF (LocalVar%Time >= LocalVar%Y_YawEndT) THEN        ! Check if the turbine is currently yawing
                avrSWAP(48) = 0.0                                ! Set yaw rate to zero
            
                LocalVar%Y_ErrLPFFast = LPFilter(LocalVar%Y_MErr, LocalVar%DT, CntrPar%Y_omegaLPFast, LocalVar%FP, LocalVar%iStatus, .FALSE., objInst%instLPF)        ! Fast low pass filtered yaw error with a frequency of 1
                LocalVar%Y_ErrLPFSlow = LPFilter(LocalVar%Y_MErr, LocalVar%DT, CntrPar%Y_omegaLPSlow, LocalVar%FP, LocalVar%iStatus, .FALSE., objInst%instLPF)        ! Slow low pass filtered yaw error with a frequency of 1/60
            
                LocalVar%Y_AccErr = LocalVar%Y_AccErr + LocalVar%DT*SIGN(LocalVar%Y_ErrLPFFast**2, LocalVar%Y_ErrLPFFast)    ! Integral of the fast low pass filtered yaw error
            
                IF (ABS(LocalVar%Y_AccErr) >= CntrPar%Y_ErrThresh) THEN                                   ! Check if accumulated error surpasses the threshold
                    LocalVar%Y_YawEndT = ABS(LocalVar%Y_ErrLPFSlow/CntrPar%Y_Rate) + LocalVar%Time        ! Yaw to compensate for the slow low pass filtered error
                END IF
            ELSE
                avrSWAP(48) = SIGN(CntrPar%Y_Rate, LocalVar%Y_MErr)        ! Set yaw rate to predefined yaw rate, the sign of the error is copied to the rate
                LocalVar%Y_ErrLPFFast = LPFilter(LocalVar%Y_MErr, LocalVar%DT, CntrPar%Y_omegaLPFast, LocalVar%FP, LocalVar%iStatus, .TRUE., objInst%instLPF)        ! Fast low pass filtered yaw error with a frequency of 1
                LocalVar%Y_ErrLPFSlow = LPFilter(LocalVar%Y_MErr, LocalVar%DT, CntrPar%Y_omegaLPSlow, LocalVar%FP, LocalVar%iStatus, .TRUE., objInst%instLPF)        ! Slow low pass filtered yaw error with a frequency of 1/60
                LocalVar%Y_AccErr = 0.0    ! "
            END IF
        END IF

        ! If using open loop yaw rate control, overwrite controlled output
        ! Open loop torque control
        IF ((CntrPar%OL_Mode == 1) .AND. (CntrPar%Ind_YawRate > 0)) THEN
            IF (LocalVar%Time >= CntrPar%OL_Breakpoints(1)) THEN
                avrSWAP(48) = interp1d(CntrPar%OL_Breakpoints,CntrPar%OL_YawRate,LocalVar%Time, ErrVar)
            ENDIF
        ENDIF

        ! Add RoutineName to error message
        IF (ErrVar%aviFAIL < 0) THEN
            ErrVar%ErrMsg = RoutineName//':'//TRIM(ErrVar%ErrMsg)
        ENDIF

    END SUBROUTINE YawRateControl

!-------------------------------------------------------------------------------------------------------------------------------
    SUBROUTINE PTC_bladePitch(CntrPar, LocalVar)
        ! Power tracking control subroutine
        ! - Calculates the rotor speed reference and reset the speed and power errors

        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables

        TYPE(ControlParameters),    INTENT(INOUT)       :: CntrPar
        TYPE(LocalVariables),       INTENT(INOUT)       :: LocalVar
        
        ! Condition to either operate on power tracking mode or greedy mode. This is done for the turbine quick start and for possible saturation (where turbines must operate in greedy instead)
        IF ((CntrPar%PTC_PowerRef<CntrPar%VS_RtPwr) .AND. ((LocalVar%GenSpeedF> LocalVar%PTC_RotorSpeedRef*CntrPar%WE_GearboxRatio).OR.(LocalVar%PC_PitComTF > CntrPar%PC_FinePit))) THEN
            ! Replace the speed and power errors 
            LocalVar%PC_SpdErr=LocalVar%PC_SpdErr - CntrPar%PC_RefSpd + ( LocalVar%PTC_RotorSpeedRef * CntrPar%WE_GearboxRatio)
            LocalVar%PC_PwrErr=LocalVar%PC_PwrErr - CntrPar%VS_RtPwr + CntrPar%PTC_PowerRef
        ENDIF
    END SUBROUTINE PTC_bladePitch
!-------------------------------------------------------------------------------------------------------------------------------
    SUBROUTINE PTC_genTorque(CntrPar, LocalVar, ErrVar)
        ! Power tracking control subroutine
        ! - Calculates the generator torque

        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables, ErrorVariables

        TYPE(ControlParameters),    INTENT(INOUT)       :: CntrPar
        TYPE(LocalVariables),       INTENT(INOUT)       :: LocalVar
        TYPE(ErrorVariables),       INTENT(INOUT)       :: ErrVar

        ! Local variables
        REAL(8)                                  :: GenTq

        ! Compute (interpolate) the rotor speed reference based on the power reference and lookup table: 
        LocalVar%PTC_RotorSpeedRef = interp1d(CntrPar%PTC_Table_PowerRef, CntrPar%PTC_Table_RotorSpeedRef, CntrPar%PTC_PowerRef, ErrVar)
    
        ! Condition to either operate on power tracking mode or greedy mode. This is done for the turbine quick start and for possible saturation (not enough power into the wind, where turbines must operate in greedy instead)
        IF ((CntrPar%PTC_PowerRef<CntrPar%VS_RtPwr) .AND. ((LocalVar%GenSpeedF> LocalVar%PTC_RotorSpeedRef*CntrPar%WE_GearboxRatio).OR.(LocalVar%PC_PitComTF > CntrPar%PC_FinePit))) THEN
            LocalVar%PTC_GenTq =(CntrPar%PTC_PowerRef/(CntrPar%VS_GenEff/100.0))/LocalVar%GenSpeedF
            IF (CntrPar%PTC_DR_Mode==1) THEN
                LocalVar%GenTq = LocalVar%PTC_GenTq
            ELSEIF (CntrPar%PTC_DR_Mode==2) THEN
                LocalVar%GenTq = MIN(LocalVar%PTC_GenTq,LocalVar%GenTq)
            ENDIF
        ENDIF

    END SUBROUTINE PTC_genTorque
!-------------------------------------------------------------------------------------------------------------------------------
    SUBROUTINE IPC(CntrPar, LocalVar, objInst, DebugVar)
        ! Individual pitch control subroutine
        !   - Calculates the commanded pitch angles for IPC employed for blade fatigue load reductions at 1P and 2P
        !   - Includes yaw by IPC

        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables, ObjectInstances, DebugVariables
        
        TYPE(ControlParameters),    INTENT(INOUT)       :: CntrPar
        TYPE(LocalVariables),       INTENT(INOUT)       :: LocalVar
        TYPE(ObjectInstances),      INTENT(INOUT)       :: objInst
        TYPE(DebugVariables),      INTENT(INOUT)        :: DebugVar

        ! Local variables
        REAL(DbKi)                  :: PitComIPC(3), PitComIPCF(3), PitComIPC_1P(3), PitComIPC_2P(3)
        INTEGER(IntKi)               :: K                                       ! Integer used to loop through turbine blades
        REAL(DbKi)                  :: axisTilt_1P, axisYaw_1P, axisYawF_1P    ! Direct axis and quadrature axis outputted by Coleman transform, 1P
        REAL(DbKi)                  :: axisTilt_2P, axisYaw_2P, axisYawF_2P    ! Direct axis and quadrature axis outputted by Coleman transform, 1P
        REAL(DbKi)                  :: axisYawIPC_1P                           ! IPC contribution with yaw-by-IPC component
        REAL(DbKi)                  :: Y_MErrF, Y_MErrF_IPC                    ! Unfiltered and filtered yaw alignment error [rad]
        
        
        ! Body
        ! Pass rootMOOPs through the Coleman transform to get the tilt and yaw moment axis
        CALL ColemanTransform(LocalVar%rootMOOPF, LocalVar%Azimuth, NP_1, axisTilt_1P, axisYaw_1P)
        CALL ColemanTransform(LocalVar%rootMOOPF, LocalVar%Azimuth, NP_2, axisTilt_2P, axisYaw_2P)

        ! High-pass filter the MBC yaw component and filter yaw alignment error, and compute the yaw-by-IPC contribution
        IF (CntrPar%Y_ControlMode == 2) THEN
            Y_MErrF = SecLPFilter(LocalVar%Y_MErr, LocalVar%DT, CntrPar%Y_IPC_omegaLP, CntrPar%Y_IPC_zetaLP, LocalVar%FP, LocalVar%iStatus, LocalVar%restart, objInst%instSecLPF)
            Y_MErrF_IPC = PIController(Y_MErrF, CntrPar%Y_IPC_KP(1), CntrPar%Y_IPC_KI(1), -CntrPar%Y_IPC_IntSat, CntrPar%Y_IPC_IntSat, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI)
        ELSE
            axisYawF_1P = axisYaw_1P
            Y_MErrF = 0.0
            Y_MErrF_IPC = 0.0
        END IF
        
        ! Integrate the signal and multiply with the IPC gain
        IF ((CntrPar%IPC_ControlMode >= 1) .AND. (CntrPar%Y_ControlMode /= 2)) THEN
            LocalVar%IPC_axisTilt_1P = PIController(axisTilt_1P, CntrPar%IPC_KP(1), CntrPar%IPC_KI(1), -CntrPar%IPC_IntSat, CntrPar%IPC_IntSat, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) 
            LocalVar%IPC_axisYaw_1P = PIController(axisYawF_1P, CntrPar%IPC_KP(1), CntrPar%IPC_KI(1), -CntrPar%IPC_IntSat, CntrPar%IPC_IntSat, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) 
            
            IF (CntrPar%IPC_ControlMode >= 2) THEN
                LocalVar%IPC_axisTilt_2P = PIController(axisTilt_2P, CntrPar%IPC_KP(2), CntrPar%IPC_KI(2), -CntrPar%IPC_IntSat, CntrPar%IPC_IntSat, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) 
                LocalVar%IPC_axisYaw_2P = PIController(axisYawF_2P, CntrPar%IPC_KP(2), CntrPar%IPC_KI(2), -CntrPar%IPC_IntSat, CntrPar%IPC_IntSat, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) 
            END IF
        ELSE
            LocalVar%IPC_axisTilt_1P = 0.0
            LocalVar%IPC_axisYaw_1P = 0.0
            LocalVar%IPC_axisTilt_2P = 0.0
            LocalVar%IPC_axisYaw_2P = 0.0
        END IF
        
        ! Add the yaw-by-IPC contribution
        axisYawIPC_1P = LocalVar%IPC_axisYaw_1P + Y_MErrF_IPC
        
        ! Pass direct and quadrature axis through the inverse Coleman transform to get the commanded pitch angles
        CALL ColemanTransformInverse(LocalVar%IPC_axisTilt_1P, axisYawIPC_1P, LocalVar%Azimuth, NP_1, CntrPar%IPC_aziOffset(1), PitComIPC_1P)
        CALL ColemanTransformInverse(LocalVar%IPC_axisTilt_2P, LocalVar%IPC_axisYaw_2P, LocalVar%Azimuth, NP_2, CntrPar%IPC_aziOffset(2), PitComIPC_2P)
        
        ! Sum nP IPC contributions and store to LocalVar data type
        DO K = 1,LocalVar%NumBl
            PitComIPC(K) = PitComIPC_1P(K) + PitComIPC_2P(K)
            
            ! Optionally filter the resulting signal to induce a phase delay
            IF (CntrPar%IPC_CornerFreqAct > 0.0) THEN
                PitComIPCF(K) = LPFilter(PitComIPC(K), LocalVar%DT, CntrPar%IPC_CornerFreqAct, LocalVar%FP, LocalVar%iStatus, LocalVar%restart, objInst%instLPF)
            ELSE
                PitComIPCF(K) = PitComIPC(K)
            END IF
            
            LocalVar%IPC_PitComF(K) = PitComIPCF(K)
        END DO

        ! debugging
        DebugVar%axisTilt_1P = axisTilt_1P
        DebugVar%axisYaw_1P = axisYaw_1P
        DebugVar%axisTilt_2P = axisTilt_2P
        DebugVar%axisYaw_2P = axisYaw_2P

        
    END SUBROUTINE IPC
!-------------------------------------------------------------------------------------------------------------------------------
    SUBROUTINE ForeAftDamping(CntrPar, LocalVar, objInst)
        ! Fore-aft damping controller, reducing the tower fore-aft vibrations using pitch

        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables, ObjectInstances
        
        ! Local variables
        INTEGER(IntKi) :: K    ! Integer used to loop through turbine blades

        TYPE(ControlParameters), INTENT(INOUT)  :: CntrPar
        TYPE(LocalVariables), INTENT(INOUT)     :: LocalVar
        TYPE(ObjectInstances), INTENT(INOUT)    :: objInst
        
        ! Body
        LocalVar%FA_AccHPFI = PIController(LocalVar%FA_AccHPF, 0.0_DbKi, CntrPar%FA_KI, -CntrPar%FA_IntSat, CntrPar%FA_IntSat, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI)
        
        ! Store the fore-aft pitch contribution to LocalVar data type
        DO K = 1,LocalVar%NumBl
            LocalVar%FA_PitCom(K) = LocalVar%FA_AccHPFI
        END DO
        
    END SUBROUTINE ForeAftDamping
!-------------------------------------------------------------------------------------------------------------------------------
    REAL(DbKi) FUNCTION FloatingFeedback(LocalVar, CntrPar, objInst) 
    ! FloatingFeedback defines a minimum blade pitch angle based on a lookup table provided by DISON.IN
    !       Fl_Mode = 0, No feedback
    !       Fl_Mode = 1, Proportional feedback of nacelle velocity (translational)
    !       Fl_Mode = 2, Proportional feedback of nacelle velocity (rotational)
        USE ROSCO_Types, ONLY : LocalVariables, ControlParameters, ObjectInstances
        IMPLICIT NONE
        ! Inputs
        TYPE(ControlParameters), INTENT(IN)     :: CntrPar
        TYPE(LocalVariables), INTENT(INOUT)     :: LocalVar 
        TYPE(ObjectInstances), INTENT(INOUT)    :: objInst
        ! Allocate Variables 
        REAL(DbKi)                      :: FA_vel ! Tower fore-aft velocity [m/s]
        REAL(DbKi)                      :: NacIMU_FA_vel ! Tower fore-aft pitching velocity [rad/s]
        
        ! Calculate floating contribution to pitch command
        FA_vel = PIController(LocalVar%FA_AccF, 0.0_DbKi, 1.0_DbKi, -100.0_DbKi , 100.0_DbKi ,LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) ! NJA: should never reach saturation limits....
        NacIMU_FA_vel = PIController(LocalVar%NacIMU_FA_AccF, 0.0_DbKi, 1.0_DbKi, -100.0_DbKi , 100.0_DbKi ,LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) ! NJA: should never reach saturation limits....
        if (CntrPar%Fl_Mode == 1) THEN
            FloatingFeedback = (0.0_DbKi - FA_vel) * CntrPar%Fl_Kp !* LocalVar%PC_KP/maxval(CntrPar%PC_GS_KP)
        ELSEIF (CntrPar%Fl_Mode == 2) THEN
            FloatingFeedback = (0.0_DbKi - NacIMU_FA_vel) * CntrPar%Fl_Kp !* LocalVar%PC_KP/maxval(CntrPar%PC_GS_KP)
        END IF

    END FUNCTION FloatingFeedback
!-------------------------------------------------------------------------------------------------------------------------------
    SUBROUTINE FlapControl(avrSWAP, CntrPar, LocalVar, objInst)
        ! Yaw rate controller
        !       Y_ControlMode = 0, No yaw control
        !       Y_ControlMode = 1, Simple yaw rate control using yaw drive
        !       Y_ControlMode = 2, Yaw by IPC (accounted for in IPC subroutine)
        USE ROSCO_Types, ONLY : ControlParameters, LocalVariables, ObjectInstances
    
        REAL(ReKi), INTENT(INOUT) :: avrSWAP(*) ! The swap array, used to pass data to, and receive data from, the DLL controller.
    
        TYPE(ControlParameters), INTENT(INOUT)    :: CntrPar
        TYPE(LocalVariables), INTENT(INOUT)       :: LocalVar
        TYPE(ObjectInstances), INTENT(INOUT)      :: objInst
        ! Internal Variables
        INTEGER(IntKi)              :: K
        REAL(DbKi)                  :: RootMyb_Vel(3)
        REAL(DbKi)                  :: RootMyb_VelErr(3)
        REAL(DbKi)                  :: axisTilt_1P, axisYaw_1P    ! Direct axis and quadrature axis outputted by Coleman transform, 1P
        REAL(DbKi)                  :: Flp_axisTilt_1P, Flp_axisYaw_1P ! Flap command in direct and quadrature axis coordinates
        ! Flap control
        IF (CntrPar%Flp_Mode > 0) THEN
            IF (LocalVar%iStatus == 0) THEN
                LocalVar%RootMyb_Last(1) = 0 - LocalVar%rootMOOP(1)
                LocalVar%RootMyb_Last(2) = 0 - LocalVar%rootMOOP(2)
                LocalVar%RootMyb_Last(3) = 0 - LocalVar%rootMOOP(3)
                ! Initial Flap angle
                LocalVar%Flp_Angle(1) = CntrPar%Flp_Angle
                LocalVar%Flp_Angle(2) = CntrPar%Flp_Angle
                LocalVar%Flp_Angle(3) = CntrPar%Flp_Angle
                ! Initialize controller
                IF (CntrPar%Flp_Mode == 2) THEN
                    LocalVar%Flp_Angle(K) = PIIController(RootMyb_VelErr(K), 0 - LocalVar%Flp_Angle(K), CntrPar%Flp_Kp, CntrPar%Flp_Ki, 0.05, -CntrPar%Flp_MaxPit , CntrPar%Flp_MaxPit , LocalVar%DT, 0.0, LocalVar%piP, LocalVar%restart, objInst%instPI)
                ENDIF
            
            ! Steady flap angle
            ELSEIF (CntrPar%Flp_Mode == 1) THEN
                LocalVar%Flp_Angle(1) = LocalVar%Flp_Angle(1) 
                LocalVar%Flp_Angle(2) = LocalVar%Flp_Angle(2) 
                LocalVar%Flp_Angle(3) = LocalVar%Flp_Angle(3) 

            ! PII flap control
            ELSEIF (CntrPar%Flp_Mode == 2) THEN
                DO K = 1,LocalVar%NumBl
                    ! Find flap angle command - includes an integral term to encourage zero flap angle
                    LocalVar%Flp_Angle(K) = PIIController(-LocalVar%rootMOOPF(K), 0 - LocalVar%Flp_Angle(K), CntrPar%Flp_Kp, CntrPar%Flp_Ki, REAL(0.05,DbKi), -CntrPar%Flp_MaxPit , CntrPar%Flp_MaxPit , LocalVar%DT, 0.0, LocalVar%piP, LocalVar%restart, objInst%instPI)
                    ! Saturation Limits
                    LocalVar%Flp_Angle(K) = saturate(LocalVar%Flp_Angle(K), -CntrPar%Flp_MaxPit, CntrPar%Flp_MaxPit) * R2D
                END DO

            ! Cyclic flap Control
            ELSEIF (CntrPar%Flp_Mode == 3) THEN
                ! Pass rootMOOPs through the Coleman transform to get the tilt and yaw moment axis
                CALL ColemanTransform(LocalVar%rootMOOPF, LocalVar%Azimuth, NP_1, axisTilt_1P, axisYaw_1P)

                ! Apply PI control
                Flp_axisTilt_1P = PIController(axisTilt_1P, CntrPar%Flp_Kp, CntrPar%Flp_Ki, -CntrPar%Flp_MaxPit, CntrPar%Flp_MaxPit, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) 
                Flp_axisYaw_1P = PIController(axisYaw_1P, CntrPar%Flp_Kp, CntrPar%Flp_Ki, -CntrPar%Flp_MaxPit, CntrPar%Flp_MaxPit, LocalVar%DT, 0.0_DbKi, LocalVar%piP, LocalVar%restart, objInst%instPI) 
            
                ! Pass direct and quadrature axis through the inverse Coleman transform to get the commanded pitch angles
                CALL ColemanTransformInverse(Flp_axisTilt_1P, Flp_axisYaw_1P, LocalVar%Azimuth, NP_1, 0.0_DbKi, LocalVar%Flp_Angle)
                
            ENDIF

            ! Send to AVRSwap
            avrSWAP(120) = LocalVar%Flp_Angle(1)   ! Send flap pitch command (deg)
            avrSWAP(121) = LocalVar%Flp_Angle(2)   ! Send flap pitch command (deg)
            avrSWAP(122) = LocalVar%Flp_Angle(3)   ! Send flap pitch command (deg)
        ELSE
            RETURN
        ENDIF
    END SUBROUTINE FlapControl
END MODULE Controllers
