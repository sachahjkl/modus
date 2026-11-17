type: Fixed

**`ring.pop` refuses counters that say more records than the queue holds**: a writer that wrote its counter more than the capacity past the counter of the reader made `pop` give a record for each count. `pop` now gives no record and changes no counter, as `push` refuses such counters.
