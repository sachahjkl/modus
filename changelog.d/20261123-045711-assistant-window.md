type: Added

**The assistant: an agent from the desktop**: the window `assistant` takes a request of the principal and shows the reply of an agent, each act that it proposes and its result. The agent runner `modustool assistant` on the host reads the request through `remote`, asks a language model whose endpoint and key stay on the host, refuses a malformed model reply whole with its error record, and runs each act only through the host agent bridge.
