title: The network device reads the data of a send where the program wrote it
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/NETWORK.md

A program writes a datagram or a TCP segment in its own datagram region. The network device now reads the data from there.

The network service copies only the first 8 bytes of the header, to check the ports against the grant of the program. It writes the headers of IPv4 and Ethernet before them. It reads no byte of the data.

The frame service holds each datagram region with the right Read only. On a machine with the IOMMU, the device can read the region and cannot write it.

A program gets the completion of its send when the device has read the datagram. It writes the same place again only after that.

When a program stops, the log of the network service gives the bytes of the data that it read on send: 0.
