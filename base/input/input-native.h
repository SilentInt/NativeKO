/*
    KOReader: generic native/Linux input platform hooks.

    The native backend opens evdev nodes directly and does not use KOReader's
    fake_events pipe. Provide the required hook as a no-op.
*/

#ifndef _KO_INPUT_NATIVE_H
#define _KO_INPUT_NATIVE_H

static void generateFakeEvent(int pipefd[2])
{
    (void) pipefd;
}

#endif
