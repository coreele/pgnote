# Expr

`select * from tb where a = 1`

```
exec_simple_query
    PortalStart | ExecutorStart | standard_ExecutorStart
        InitPlan
            ExecInitNode
                ExecInitSeqScan
                    ExecAssignExprContext
                        planstate->ps_ExprContext = CreateExprContext(estate);
                            CreateExprContextInternal
                    scanstate->ss.ps.qual = ExecInitQual
                        state = makeNode(ExprState);
                        ExecCreateExprSetupSteps(state, (Node *) qual); /* Insert setup steps as needed */
                            expr_setup_walker /* Prescan to find out what we need. */
                            ExecPushExprSetupSteps /* And generate those steps. */
                        ExecInitExprRec /* for each target */
                            ExecInitFunc
                            [EEOP_SCAN_FETCHSOME, EEOP_SCAN_VAR, EEOP_FUNCEXPR_STRICT, EEOP_QUAL, EEOP_DONE]
                        ExecReadyExpr
                            ExecReadyInterpretedExpr
                                ExecInitInterpreter
                                state->evalfunc = ExecInterpExprStillValid;
                                state->evalfunc_private = (void *) ExecInterpExpr;
    PortalRun | PortalRunSelect | ExecutorRun | standard_ExecutorRun
        ExecutePlan | ExecProcNode | ExecProcNodeFirst
            ExecSeqScan | ExecScan | ExecProject
                ExecEvalExprSwitchContext
	                ExecInterpExprStillValid
		                ExecInterpExpr
                            EEO_DISPATCH(EEO_SWITCH), EEO_CASE, EEO_NEXT
```
