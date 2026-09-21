# Spec Delta: api-client

## MODIFIED Requirements

### Requirement: API key never in argv

The client SHALL write the `Authorization` header (or the provider's
equivalent auth header) to a private temp file and pass it to curl via
`-H @<file>`; the key SHALL not appear in the process argv or in the
environment. The temp file SHALL be created with mode 600 so there is
no window in which the key is readable by other users; if the mode
cannot be applied the client SHALL fail before issuing the request.
The header file and request body file SHALL be removed after the
request, on both success and failure.

#### Scenario: Key not visible in ps
- **WHEN** a request is in flight
- **THEN** `ps` shows the curl command with `-H @/tmp/...`, not the
  key text

#### Scenario: Header file is private from creation
- **WHEN** the header file is written and before curl starts
- **THEN** its mode is already 600 and no other user can read it

#### Scenario: Temp files are cleaned up
- **WHEN** the request finishes, succeeds or fails
- **THEN** both the header file and the request body file no longer exist
