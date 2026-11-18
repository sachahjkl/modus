title: A program holds data with no known bound in an arena
date: 2026-11-18
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

modus is an operating system with a small kernel, in which a budget pays for each page that a program uses.

A program can now hold data whose size it cannot know before it reads it, such as the tree of a document, in an arena. An arena reserves a range of addresses once and commits its pages as it grows. When the budget cannot pay the next pages, the push gives back the status `No_Budget`: the program reads it and keeps running. An arena never moves, and its end gives every page back to the budget at once.

The test program `arena` grows an arena one page at a time until its budget refuses, then checks that a reset takes the same pages again with no commit, and that its budget comes back whole after the end.
