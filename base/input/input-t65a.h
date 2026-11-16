/*
    KOReader: generic i.MX6 / Likebook T65A input platform hooks.

    The native T65A backend opens /dev/input/event0 (gpio-keys) and
    /dev/input/event1 (goodix-ts) directly and does not use KOReader's
    fake_events pipe. Provide the required hook as a no-op.
*/

#ifndef _KO_INPUT_T65A_H
#define _KO_INPUT_T65A_H

static void generateFakeEvent(int pipefd[2])
{
    (void) pipefd;
}

#endif
