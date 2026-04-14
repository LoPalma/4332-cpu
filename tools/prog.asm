# test program
start:
        loadimm %0, 0x1234
        mov/w %1, %0
        loadimm %2, 0x4321
        add/d/z %2, %1
        hlt
