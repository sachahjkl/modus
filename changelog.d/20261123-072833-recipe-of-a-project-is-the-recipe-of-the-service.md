type: Changed

**The recipe of an evaluated project is the recipe that `recipes` builds.** A project's output now reaches recipes.register under one hash: here() gives a tree and module(...) a module file, each an input that names its kind, and the evaluator and the service compute the recipe hash with the same conversion. A bare hash in the arguments of a recipe, a builder given by a bare hash, and a project source that is a bare hash are refused.
