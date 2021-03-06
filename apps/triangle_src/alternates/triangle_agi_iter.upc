/******************************************************************
//
//
//  Copyright(C) 2018, Institute for Defense Analyses
//  4850 Mark Center Drive, Alexandria, VA; 703-845-2500
//  This material may be reproduced by or for the US Government
//  pursuant to the copyright license under the clauses at DFARS
//  252.227-7013 and 252.227-7014.
// 
//
//  All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//    * Redistributions of source code must retain the above copyright
//      notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above copyright
//      notice, this list of conditions and the following disclaimer in the
//      documentation and/or other materials provided with the distribution.
//    * Neither the name of the copyright holder nor the
//      names of its contributors may be used to endorse or promote products
//      derived from this software without specific prior written permission.
// 
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
//  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
//  COPYRIGHT HOLDER NOR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
//  INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
//  STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
//  OF THE POSSIBILITY OF SUCH DAMAGE.
// 
 *****************************************************************/ 
/*! \file triangle_agi_iter.upc
 * \brief The intuitive implementation of triangle counting 
 * that uses global references hidden behind "iterators"
 */

#include "triangle.h"

// ALWAYS use the global view of rows, 
// even if we need to localize them behind the scene

typedef struct my_row_iter_t {
  int64_t cur_row;            // the global name for a local row
  int64_t num_rows;        // the global number of rows
}my_row_iter_t;

int64_t my_row_iter_init(my_row_iter_t *riter, sparsemat_t *mat)
{
  riter->cur_row=MYTHREAD;
  riter->num_rows=mat->numrows;
  return( riter->cur_row );
}

int64_t my_row_iter_next(my_row_iter_t *riter)
{
  riter->cur_row += THREADS;
  return( ((riter->cur_row)< riter->num_rows) ? riter->cur_row: -1);
}

// The idea is that we always reference non_zeros with a (thread, local index) pair
// in the case where we know the row is local we short-curcuit the arith and
// use a local pointer
#define COL_CACHE_SZ 32
typedef struct col_iter_t {
  bool using_local;
  sparsemat_t *mat;
  int64_t pe, l_row;
  int64_t idx_range[2];// holds index into nonzeros: idx_range[0] = current, idx_range[1] is one to_many
  int64_t ntg;
  int64_t c_idx;
  int64_t cached[COL_CACHE_SZ];  // we will get a block of nonzero if we can
}col_iter_t;


int64_t col_iter_init( col_iter_t *citer, sparsemat_t *mat, int64_t Row)
{
   if( (Row%THREADS) == MYTHREAD ) { 
      citer->using_local = true;
      citer->mat = mat;
      citer->pe = MYTHREAD;
      citer->l_row = Row / THREADS;
      citer->idx_range[0] = mat->loffset[ citer->l_row ];
      citer->idx_range[1] = mat->loffset[ citer->l_row + 1];
      if( citer->idx_range[0] < citer->idx_range[1] )
        return( mat->lnonzero[citer->idx_range[0]] );
      else
        return( -1 );
   } else {
      citer->using_local = false;
      citer->mat = mat;
      citer->pe = Row % THREADS;
      citer->l_row = Row / THREADS;
      citer->ntg = 0;
      citer->c_idx = 0;
#pragma unroll 0
      for(int k=0; k<2;k++)
        citer->idx_range[k] = mat->offset[ Row + k*THREADS ]; // pattern match to get both?

      if( citer->idx_range[0] < citer->idx_range[1] ){
        citer->ntg = citer->idx_range[1] - citer->idx_range[0];
        citer->ntg = ((citer->ntg) > COL_CACHE_SZ) ? COL_CACHE_SZ : citer->ntg;
        for(int k=0; k<citer->ntg; k++)
//#pragma pgas defer_sync 
          citer->cached[k] = mat->nonzero[(citer->idx_range[0] + k) * THREADS + citer->pe];
        citer->idx_range[0] += citer->ntg;
//        upc_fence;
        return( citer->cached[citer->c_idx] );
      } else {
        return( -1 );
      }
   }
}


int64_t col_iter_next( col_iter_t *citer)
{
  if( citer->using_local == true ) {
    citer->idx_range[0] += 1;
    if( citer->idx_range[0] < citer->idx_range[1] )
      return( citer->mat->lnonzero[citer->idx_range[0]] );
    else
      return( -1 );
  } else {
    citer->c_idx += 1;
    if( citer->c_idx < citer->ntg )
      return( citer->cached[citer->c_idx] );
    else {
      if( citer->idx_range[0] < citer->idx_range[1] ){
        citer->ntg = citer->idx_range[1] - citer->idx_range[0];
        citer->ntg = ((citer->ntg) > COL_CACHE_SZ) ? COL_CACHE_SZ : citer->ntg;
        for(int k=0; k<citer->ntg; k++)
//#pragma pgas defer_sync 
          citer->cached[k] = citer->mat->nonzero[(citer->idx_range[0] + k) * THREADS + citer->pe];
        citer->idx_range[0] += citer->ntg;
        citer->c_idx = 0;
//        upc_fence;
        return( citer->cached[citer->c_idx] );
      } else {
        return( -1 );
      }
    }
  }
}


/*!
 * \brief This routine implements the agi variant of triangle counting
 * \param *count a place to return the counts from this thread
 * \param *sr a place to return the number of shared references
 * \param *mat the input sparse matrix 
 *        NB: This must be the tidy lower triangular matrix from the adjacency matrix
 * \return average run time
 */
double triangle_agi_iter(int64_t *count, int64_t *sr, sparsemat_t * Lmat, sparsemat_t * Umat, int64_t alg){
  int64_t cnt=0;
  int64_t numpulled=0;
  int64_t U,W,V,H;
  my_row_iter_t U_iter;
  col_iter_t V_iter, W_Iter, H_iter;

  double t1 = wall_seconds();
  // for all edges {U,V} in L
  for(U = my_row_iter_init(&U_iter, Lmat); U != -1; U = my_row_iter_next(&U_iter) ) {
    V = col_iter_init(&V_iter, Lmat, U);  // returns the first non-zero
    // The first non-zero can't contribute, so we skip by calling next to start the for loop
    for( V = col_iter_next(&V_iter); V != -1; V = col_iter_next(&V_iter) ) {
      // Look for a vertex that forms a wedge or is hinge between U and V.
      // I.e., find W such that {V,W} and {U,W} are edges.

      W = col_iter_init(&W_Iter, Lmat, V);
      numpulled +=3; // charge for the offsets and first ref,  we don't worry about the buffering
      H = col_iter_init(&H_iter, Lmat, U); 
      while( W!=-1 && H!=-1){
        if(W == H){
          cnt++;
          W = col_iter_next(&W_Iter);
          numpulled++;
          H = col_iter_next(&H_iter);
        }else if(W < H){
          W = col_iter_next(&W_Iter);
          numpulled++;
        }else{ // W > H
          H = col_iter_next(&H_iter);
        }
      }
      if(W == -1) numpulled--;  //shouldn't get charged for the last call to next
    }
  }

  lgp_barrier();
  minavgmaxD_t stat[1];
  t1 = wall_seconds() - t1;
  lgp_min_avg_max_d( stat, t1, THREADS );

  *sr = numpulled; 
  *count = cnt;
  return(stat->avg);
}
