# Simulator

Just an application to help simulate use cases of Klife and test it under various scenarios

## Invariants

- Not consume duplicate messages
  - Try to insert_new on an ETS after consuming it successfully
- Do not consume messages out of order
  - Check the monotonically increasing value inside the record and comparing it to the latest processed value
- Do not skip any message
  - Compare the ETS of produced messages against the ETS of consumed messages
