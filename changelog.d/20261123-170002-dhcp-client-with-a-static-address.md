type: Added

**A DHCP client with a static address from the plan.** The network service takes the address of the machine from DHCP, with its lease and its renewal, and refuses each reply whose fields a machine cannot hold; a plan of principal 0 can give a static address in its place. Until an address holds, a request of an endpoint waits for it.
