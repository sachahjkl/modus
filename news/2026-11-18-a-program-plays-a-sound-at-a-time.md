title: A program plays a sound at the time that it names
date: 2026-11-18
release: next
picture: none
kind: Shown
guide: docs/SOUND.md

modus is an operating system with a small kernel, in which the code that drives a device is an ordinary program with the handles of that device only.

A program can now play sound. It writes its samples in memory of its own and sends records to the sound service, each with the time of its first sample by the clock of the system. The service plays each record at that time, and silence between the records. A record that comes too late plays nothing: the program gets a refusal with the earliest time that it could take.

The program `tone` plays a tone of 440 Hz half a second after the start of its stream. The test machine writes its sound output to a file, and the test finds the tone there at the sample of its time.
