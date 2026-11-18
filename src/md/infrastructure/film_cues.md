# Film cues

A film cue is a named moment of a film: the time since its start when its scene reached a state. The tutorial of the system is edited outside this repository, from the films `boot`, `desktop`, `console` and `program`. Its captions must appear when the state that they describe is on the screen. The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The film cues".

## The constraint

A film has the speed of the machine ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The film"): each scene waits for its line of the log, and a slow host makes a longer film. A caption placed at a time that the editor guesses from the holds is right on one host and drifts on another. The only party that knows when a state was reached is the tool, at the end of the wait of the scene.

## The chosen form

- **The hold names the cue.** A step `Film_Hold` with a text starts the cue of that name. The hold comes after the wait of its scene, so its start is the moment the state is on the screen. The text of `Film_Hold` had no use before; the cue costs no new step kind.
- **The tool writes times, the editor writes words.** The cue file holds a name and a time, never the text of a caption. The captions are in the editor, in its language and its layout; the scenario only names the moments. A change of a caption does not change a scenario.
- **One line for each cue**, the time in seconds with milliseconds, one space, the name. A reader reads it with no parser library. The time is cut, not rounded, so a caption never comes before its state.
- **A name is a key**: lowercase letters, digits, `_` and `.`, a letter first, 48 bytes at most, once in a film. The tool refuses another name at the step and fails the film; a host test checks the names of each film of the tool. The editor refuses a cue file with a name that it has no caption for, and a caption with no cue: the two lists stay equal.
- **An empty file for a film with no cue**, so the file of an earlier run never stays beside a new film.

## The refused forms

- **Times in the editor, from the holds of the scenario.** They drift with the speed of the host, and a change of a hold changes the editor.
- **The caption text in the scenario.** The scenario would hold the words of another project, and a new caption would need a new film.
- **A new step kind `Film_Cue`.** Each whole switch over the step kinds would need a case, for a step that has no time of its own; a cue always starts a hold, because a viewer needs the time to read its caption.
- **The time of the picture of the state.** The worker names a picture by the time when it asked for it; the scenario does not know which picture first holds the state. The start of the hold is a bound that the scenario knows, and the difference is less than one slot of the film.
- **A WebVTT file of captions.** It holds the text of the captions, which belongs to the editor, and each cue would need an end that the next cue already gives.

## The subtle points

- The time of a cue is the time of the film: the first picture of a film is at the start of the worker, and the list of the encoder starts the film with that picture.
- A machine that is paused by a step `Monitor "stop"` (the film `boot`) still gives pictures, so a cue during a pause has its real time in the film.

## State

Built: the cues, the cue file, the check of the names, and the cues of the films `boot`, `desktop`, `console` and `program`. The films `terminal`, `palette` and `heron` have no cue.
