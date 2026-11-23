type: Changed

**More clients for each service and for the network**: each service takes 48 callers at once (was 8), the network service 96 endpoints, `remote` reaches 8 paired machines at once (was 2), and the QUIC server keeps the budgets of 1024 source ranges, with a prefix length that its limits set, in place of 64.
