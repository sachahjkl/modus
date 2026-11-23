title: A recipe in a declaration has the hash that the service builds
date: 2026-11-23
release: next
picture: none
kind: Decided
guide: docs/LEX.md

In a declaration, here() now gives a tree reference: a value that holds the tree hash of the source of the project and says that it is a tree. module(...) gives a module file.

A recipe takes these two values as its inputs. A bare hash names no kind, so a recipe refuses it, and the evaluation says why.

The evaluation and the service recipes read a recipe with one conversion. So the hash of the recipe of a project is the hash under which recipes registers it.
