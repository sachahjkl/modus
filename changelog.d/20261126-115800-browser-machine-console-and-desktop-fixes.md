type: Fixed

**Web Console `isolate("sample")` and `processes()`, and Web Desktop cursor alignment and frame throughput**: included the `host` call-host module in the console and browser desktop images (alongside `files` and `code` in Web Desktop), enabled `processes()` to inspect running processes directly on headless console images without `monitor`, aligned the Web Desktop cursor 1:1 with canvas coordinates via chunked PS/2 homing, and skipped redundant worker state and unchanged-frame copies.
