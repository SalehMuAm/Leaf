# Security

Leaf is public beta software. Security fixes target the latest published beta; older versions do not have a separate support commitment.

## Reporting a vulnerability

Report vulnerabilities privately using [GitHub's vulnerability reporting form](https://github.com/SalehMuAm/Leaf/security/advisories/new). Include the affected Leaf and macOS versions, reproduction steps, potential impact, and a minimal synthetic PDF or other safe test case.

Do not put exploit details, credentials, or sensitive documents in a public issue. If private reporting is unavailable, open a public issue requesting a private reporting channel without including the vulnerability details.

## Security scope

Leaf processes PDFs locally using Apple's PDFKit. The app does not include a document upload service, analytics client, or automatic update service. It does not upload opened documents, saved annotations, exports, or recent-document paths. Files stored in folders synced by macOS or other services remain subject to those services' behavior.

PDF parsing and rendering depend on macOS frameworks. Include the operating system version in reports, since behavior can vary between framework versions. Report Leaf-specific problems with opening, saving, annotations, permissions, or file handling through the process above.

The 1.2.1 beta package is built for Apple silicon and uses an ad hoc code signature. It is not Developer ID signed or notarized by Apple. Check the release notes for the signing status of later artifacts. Do not disable system-wide security protections to run Leaf.
