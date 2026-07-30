# Recovery guide

`voiceEvents()` and `runtimeSnapshot()` are the recovery contract. If an event
stream reports a delivery failure, fetch a snapshot before offering the next
voice action. `recoveryState` is the authority for new audio work.

Only the app-owned service owner calls `close()`. If it returns `.blocked`,
keep voice controls disabled and offer an explicit retry. Do not create another
service instance or silently restart capture to work around a blocked cleanup.
