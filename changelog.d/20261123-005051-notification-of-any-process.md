type: Changed

**Any connected process can post a notification.** `compositor.notify` takes a caller that does not act for the principal: its card shows the process name of the connection before the title, and the caller holds at most 3 cards at once; one more is refused with `Full`. A caller that acts for the principal posts as before.
