# Spec Delta

## MODIFIED Requirements

### Requirement: API key never in argv
The client SHALL write the `Authorization` header (or the provider's equivalent auth header) to a private temp file (mode 600) and pass that file handle to the in-process HTTP client; the key SHALL not appear in the process argv or in the environment. The temp file SHALL be created with mode 600 before the key is written, so there is no window in which the key is readable by other users; if the mode cannot be applied the client SHALL fail before issuing the request. The header file and request body file SHALL be removed after the request, on both success and failure. When the resolved credential is an OAuth access token, the same header-file path SHALL carry `Authorization: Bearer <token>` (or the provider-specific equivalent); the token SHALL NOT be logged, journaled, or placed in argv. On a classified auth failure with a stored refresh token, the client (or the layer immediately above it) MAY perform one refresh request using the same transport rules before the caller retries.

#### Scenario: Key not visible in ps
- **WHEN** a request is in flight
- **THEN** `ps` shows no key text — the key travels only through the
  mode-600 temp header file, and no `curl` command is spawned

#### Scenario: Header file is private from creation
- **WHEN** the header file is written and before the request starts
- **THEN** its mode is already 600 and no other user can read it

#### Scenario: Temp files are cleaned up
- **WHEN** the request finishes, succeeds or fails
- **THEN** both the header file and the request body file no longer exist

#### Scenario: Key file permissions
- **WHEN** the client prepares a request with an API key
- **THEN** the header temp file exists with mode 600 before the key is written into it

#### Scenario: OAuth bearer uses header file
- **WHEN** the resolved credential is an OAuth access token
- **THEN** the header file carries the provider's bearer/authorization header with the token and argv remains clean
