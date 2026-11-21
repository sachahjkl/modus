# Contributing to modus

## How modus is built

Engineering is prototyping: build a version, profile it, measure it, adjust it, and start again. A prototype can be made by hand or with AI. AI is a tool that shortens that loop. The measure, the test and the decision stay human: a person judges whether what was produced is good, and that judgement never leaves the loop.

- The properties of the system (`docs/PROPERTIES.md`) and each decision of design come from a person, and are written in `src/md`.
- Most of the code is written by AI agents, under that direction. Each change passes a review, the host tests, the machine tests and the measures before it is merged.
- The system can be read, tested, changed and built without any AI. Nothing in the repository needs a model to work.
- Each commit is made under the identity of the person who answers for it.

## The use of AI in a contribution

You can prototype a contribution by hand or with AI. AI is welcome, and it is not required: a good idea is a good idea, whatever wrote its code.

The tool does not matter. The proof does.

## Each contribution brings its proof

A contribution without its proof is not accepted. The proof depends on what the contribution claims:

| The contribution claims | Its proof |
|---|---|
| It is faster, smaller or lighter | A measure before and after, on the same machine, with the profile that shows where the gain comes from. A claim of speed has a measured number. |
| It changes what a person sees | A picture or a film from the machine test, before and after. |
| It fixes a fault | A test that fails before the change and passes after it. |
| It adds a behaviour | Tests that try to break it: each input that it must refuse, the edges, then the successful case. |
| It changes a design | The intent file in `src/md`, changed in the same commit, with the forms that were refused and why. |

You must be able to explain each line of your contribution, and why it is right. "The model wrote it" is not an explanation.

## Each contribution states its reason, with its sources

The reason of a change can be small. It must be present, and it must be sourced:

- numbers: a measure, a profile, a size, a count;
- a picture or a film, when the change is visible;
- the values that show the fault or the gain;
- the extracts of code that show why the change is needed;
- a reference to the standard, the paper or the project of origin, when the change implements or follows a standard or a published algorithm.

## Tests that anyone can run again

When a change can be tested, give the tests that show it does what it says, and the command that runs them. A maintainer must be able to run them again on their own machine, with one command, and get the same result. A test is not required for every change, but it is the proof that is expected first.

## No slop

A contribution with no reason and no proof, or a text that says nothing, is slop. It is closed with no review.

The maintainer judges what is slop. After about five such contributions, their author is banned from the project. The number is a guide, not a right: the maintainer can act sooner.

## Who decides

The maintainers carry the vision of the project, and they decide. Today the maintainer is the founder; later, the maintainers of the project's organisation join them. A decision is not a vote.

The maintainers give the reason of each decision. If a decision is not clear to you, ask: a question is always welcome.

## Before you start

1. Read `src/md/README.md`: the system on one page, and the index of the intent files.
2. Read `docs/PROPERTIES.md`. A contribution that breaks a property is refused, unless the property changes first, by an explicit decision.
3. Read `AGENTS.md`: its rules of work apply to every contributor, human or not.
4. For a change that a reader notices, add a changelog fragment (`changelog.d/README.md`).
