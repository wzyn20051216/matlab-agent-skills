/*
 * Sponsored License - for use in support of a program or activity
 * sponsored by MathWorks.  Not for government, commercial or other
 * non-sponsored organizational use.
 *
 * codegen_target.c
 *
 * Code generation for function 'codegen_target'
 *
 */

/* Include files */
#include "codegen_target.h"
#include "rt_nonfinite.h"
#include "sumMatrixIncludeNaN.h"
#include <emmintrin.h>

/* Function Definitions */
real_T codegen_target(const real_T x[10])
{
  real_T b_y[10];
  int32_T k;
  /* CODEGEN_TARGET  Codegen-friendly reference: scaled sum of squares. */
  /*    y = 0.5 * sum(x.^2), so y(1:10) = 0.5*385 = 192.5 exactly. */
  for (k = 0; k <= 8; k += 2) {
    __m128d r;
    r = _mm_loadu_pd(&x[k]);
    _mm_storeu_pd(&b_y[k], _mm_mul_pd(r, r));
  }
  return 0.5 * sumColumnB(b_y);
}

/* End of code generation (codegen_target.c) */
