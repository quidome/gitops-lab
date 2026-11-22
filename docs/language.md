# Language

The words that all documents, code and conversations about the platform use. Change a word only
on purpose, in its own commit. Define meaning, not mechanics: no flags, paths or formats.

| Term | Meaning | Use / do not use |
|------|---------|------------------|
| platform | The cluster and the shared base it gives: networking, DNS, certificates, secrets, storage, single sign-on, monitoring | Say platform for the whole product, not "the lab" or "the cluster" when the shared base is meant |
| service | Something that runs on the platform and does one job, for a user or for the platform itself | Use for each deployed thing; "app" only for services that people use directly |
| operator | The person who builds and runs the platform | Not "admin" or "user" |
| user | A person in the household who uses a service but does not operate the platform | Never use for the operator or for a guest |
| guest | A person outside the household whom the operator lets use a few shared services over a private network | Not "user", "friend" or "external user"; a guest never gets access from the open internet |
| shared service | A service that the operator chose to make reachable for guests over the network | Not "public service"; says nothing about accounts or permissions inside the service |
| shared entry | The one device on the private network through which guests reach the shared services | Not "gateway" alone; the gateway is one part of it |
| backup | A copy of service data, stored outside the platform, that has been shown to restore | A copy that was never restored is not yet a backup that the operator can trust |
| bootstrap | The few manual command-line steps that start the platform from nothing, before git and ArgoCD take over | Not used for routine changes |
| recovery steps | Written steps to bring a service, its data, or the platform back after a failure | Part of the service document of each service |
