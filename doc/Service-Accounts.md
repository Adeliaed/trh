A [service account](https://cloud.google.com/iam/docs/understanding-service-accounts) is a special type of Google account intended to represent a non-human user that needs to authenticate and be authorized to access data in Google APIs. In G Suite domains you can use a service account to programmatically [access users data](https://developers.google.com/drive/api/v3/about-auth#perform_g_suite_domain-wide_delegation_of_authority) without any manual authorization on their part. To do so, you have to [create a service account](https://developers.google.com/identity/protocols/OAuth2ServiceAccount#creatinganaccount), and then [enable G Suite Domain-wide Delegation](https://developers.google.com/identity/protocols/OAuth2ServiceAccount#delegatingauthority). To use this service account with `google-drive-ocamlfuse`, you can mount the filesystem with the command line option `-serviceaccountpath` to specify the path of the credential JSON file you have downloaded creating the account, and `-serviceaccountuser` to specify the email of the user to impersonate. For example:

    google-drive-ocamlfuse -serviceaccountpath /path/to/json -serviceaccountuser user@example.com /path/to/mountpoint

If you don't have a G Suite domain, you can still use a service account but you can't specify an user to impersonate. The service account has its own Drive instance, but you can share files/folders/drives between your regular user and the service account.

If you get `userRateLimitExceeded` errors, check this quota: `Queries per 100 seconds per user` in [cloud console](
https://console.cloud.google.com/apis/api/drive.googleapis.com/quotas). The default is 100 and it's too low. You can raise it to 10,000.