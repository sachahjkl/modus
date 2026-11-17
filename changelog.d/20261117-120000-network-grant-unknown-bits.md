type: Fixed

**A network grant with an unknown bit is refused**: the word of the grant of an endpoint with a bit from 51 to 63 was read as a grant with fewer rights. The network service now refuses such a word with `Bad_Value` and makes or changes no endpoint, and each network program stops at its start when its grant has one.
