/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * Minimal freestanding <sys/feature_tests.h> for the riscv64 uts bring-up
 * object.  The gate ships a large feature_tests.h driving the visibility
 * macros; here we only need the empty contract so <sys/machtypes.h> and the
 * riscv64 stanza of <sys/isa_defs.h> compile standalone before the full gate
 * headers are grafted in.  In the real gate this file is NOT replaced -- the
 * stock uts/common/sys/feature_tests.h is used.
 */
#ifndef	_SYS_FEATURE_TESTS_H
#define	_SYS_FEATURE_TESTS_H
/* deliberately minimal: no visibility gymnastics for the bring-up object */
#endif	/* _SYS_FEATURE_TESTS_H */
