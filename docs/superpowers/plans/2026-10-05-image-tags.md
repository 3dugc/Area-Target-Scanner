# Image tag publication

User requirement: use `latest` in the production configuration and publish only `latest` and `develop` tags. Do not create commit-hash image tags.

1. Publish `develop` from the develop branch and `latest` from the publish branch for both scanner and compatible optimizer. Keep main's complete runtime validation without publishing an extra tag.
2. Default the Portainer stack to `latest` and update the service login/deployment instructions. Preserve credentials, resource limits, volumes, routes and private optimizer networking.
3. Validate YAML, shell steps and the three branch mappings; independently review the changes.
4. Commit the isolated changes, then promote through develop, main and publish with each CI and runtime image gate passing before the next promotion.
5. Validate the complete private handoff configuration using `latest` for both services. Credential entry and submission in Portainer remain a user handoff, followed by live authentication and scan verification.

Existing registry tags are retained; this change controls future publications and does not delete historical images. Image digests and revision labels remain available as verification evidence, without creating additional named versions.
