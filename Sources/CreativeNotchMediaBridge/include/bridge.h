#ifndef CREATIVENOTCH_MEDIA_BRIDGE_H
#define CREATIVENOTCH_MEDIA_BRIDGE_H

/// Entry point, installed into perl as an XSUB.
///
/// The two arguments are perl's threaded calling convention (`pTHX_ CV*`)
/// and are ignored — we never touch perl's stack, which is what lets this
/// build without perl's headers.
void cn_media_stream(void *interp_unused, void *cv_unused);

#endif
