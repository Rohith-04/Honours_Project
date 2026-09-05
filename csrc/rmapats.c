// file = 0; split type = patterns; threshold = 100000; total count = 0.
#include <stdio.h>
#include <stdlib.h>
#include <strings.h>
#include "rmapats.h"

void  schedNewEvent (struct dummyq_struct * I1403, EBLK  * I1398, U  I624);
void  schedNewEvent (struct dummyq_struct * I1403, EBLK  * I1398, U  I624)
{
    U  I1667;
    U  I1668;
    U  I1669;
    struct futq * I1670;
    struct dummyq_struct * pQ = I1403;
    I1667 = ((U )vcs_clocks) + I624;
    I1669 = I1667 & ((1 << fHashTableSize) - 1);
    I1398->I666 = (EBLK  *)(-1);
    I1398->I667 = I1667;
    if (0 && rmaProfEvtProp) {
        vcs_simpSetEBlkEvtID(I1398);
    }
    if (I1667 < (U )vcs_clocks) {
        I1668 = ((U  *)&vcs_clocks)[1];
        sched_millenium(pQ, I1398, I1668 + 1, I1667);
    }
    else if ((peblkFutQ1Head != ((void *)0)) && (I624 == 1)) {
        I1398->I669 = (struct eblk *)peblkFutQ1Tail;
        peblkFutQ1Tail->I666 = I1398;
        peblkFutQ1Tail = I1398;
    }
    else if ((I1670 = pQ->I1306[I1669].I689)) {
        I1398->I669 = (struct eblk *)I1670->I687;
        I1670->I687->I666 = (RP )I1398;
        I1670->I687 = (RmaEblk  *)I1398;
    }
    else {
        sched_hsopt(pQ, I1398, I1667);
    }
}
void  rmaPropagate70_simv_daidir (UB  * pcode, scalar  val)
{
    UB  * I1737;
    *(pcode + 0) = val;
    pcode += 8;
    UB  * I742 = *(UB  **)(pcode + 0);
    if (I742 != (UB  *)(pcode + 0)) {
        RmaSwitchGate  * I1764 = (RmaSwitchGate  *)I742;
        RmaSwitchGate  * I956 = 0;
        do {
            RmaIbfPcode  * I1093 = (RmaIbfPcode  *)(((UB  *)I1764) + 24U);
            ((FP )(I1093->I1093))((void *)I1093->pcode, val);
            RmaDoublyLinkedListElem  I1765;
            I1765.I956 = 0;
            RmaSwitchGateInCbkListInfo  I1766;
            I1766.I1250 = 0;
            I956 = (RmaSwitchGate  *)I1764->I639.I1767.I956;
        } while ((UB  *)(I1764 = I956) != (UB  *)I742);
    }
}
#ifdef __cplusplus
extern "C" {
#endif
void SinitHsimPats(void);
#ifdef __cplusplus
}
#endif
