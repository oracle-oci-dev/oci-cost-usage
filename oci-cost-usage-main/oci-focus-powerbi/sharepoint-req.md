# SharePoint / Microsoft Entra setup

Legacy note: the active v3 pipeline now publishes the weekly CSV to OCI Object
Storage and gives Power BI a PAR URL. Use this document only if you deliberately
choose the older SharePoint delivery path.

What you need on the Microsoft side to let the older OCI cost pipelines upload
CSVs to a SharePoint document library for Power BI.

Applies to v1, v2, and any custom legacy SharePoint delivery script. It does
not apply to the active v3 Object Storage PAR delivery.

---

## 1. The seven values

| Variable | Where it comes from |
|---|---|
| `MS_TENANT_ID` | Entra ID → Overview → Tenant ID (a GUID) |
| `MS_CLIENT_ID` | Your app registration → Application (client) ID |
| `MS_CLIENT_SECRET` | Your app registration → Certificates & secrets |
| `SP_HOSTNAME` | From the site URL, e.g. `contoso.sharepoint.com` |
| `SP_SITE_PATH` | From the site URL, e.g. `/sites/FinOps` |
| `SP_LIBRARY_NAME` | Document library display name, usually `Documents` |
| `SP_FOLDER_PATH` | Folder inside the library, e.g. `PowerBI/OCI` |

Splitting a site URL:

```
https://contoso.sharepoint.com/sites/FinOps
        └────────┬───────────┘└────┬─────┘
          SP_HOSTNAME          SP_SITE_PATH
```

`SP_LIBRARY_NAME` is the **display name** shown in the site's left navigation.
If someone renamed it ("Shared Documents", "FinOps Docs"), use that exact name.

`SP_FOLDER_PATH` **must already exist.** Create it manually in the library
first. The Graph upload endpoint does not reliably create missing parent
folders, so the scripts pre-check the folder and stop with a clear message if
it is absent.

---

## 2. Create the app registration

Entra admin center → **Entra ID → App registrations → New registration**

- Name: something identifiable, e.g. `OCI FOCUS Uploader`
- Supported account types: **Single tenant**
- Redirect URI: **leave blank** — this is app-only (client credentials), not
  interactive user sign-in

Record the **Application (client) ID** → `MS_CLIENT_ID`
Record the **Directory (tenant) ID** → `MS_TENANT_ID`

### Client secret

**Certificates & secrets → New client secret**

- Copy the **Value** immediately. It is shown only once.
- Note the expiry date. When it lapses the pipeline fails silently at the token
  request. Set a calendar reminder ~2 weeks before.
- For production, certificate authentication is stronger than a shared secret.

---

## 3. Permissions — the step most people miss

**API permissions → Add a permission → Microsoft Graph → Application
permissions** (not *Delegated*) → select **`Sites.Selected`** → **Grant admin
consent**.

> `Sites.Selected` on its own grants access to **no sites at all.** Admin
> consent is necessary but not sufficient.

### The required second step: per-site grant

An admin must explicitly grant the app write access to your specific site.

First get the site ID:

```http
GET https://graph.microsoft.com/v1.0/sites/contoso.sharepoint.com:/sites/FinOps
```

Then grant write on that site:

```http
POST https://graph.microsoft.com/v1.0/sites/{site-id}/permissions
Content-Type: application/json

{
  "roles": ["write"],
  "grantedToIdentities": [
    {
      "application": {
        "id": "<MS_CLIENT_ID>",
        "displayName": "OCI FOCUS Uploader"
      }
    }
  ]
}
```

**If you skip this, the script fails with HTTP 403 when resolving the site.**
That is by far the most common setup failure, and the scripts' error message
names this cause explicitly.

### Alternative (broader)

`Sites.ReadWrite.All` works without the per-site grant, but gives the app write
access to **every site in the tenant**. For FedRAMP / DoD / regulated
environments, prefer `Sites.Selected` with the per-site grant.

---

## 4. Export the variables

```bash
export MS_TENANT_ID='00000000-0000-0000-0000-000000000000'
export MS_CLIENT_ID='00000000-0000-0000-0000-000000000000'
export MS_CLIENT_SECRET='<the secret value>'

export SP_HOSTNAME='contoso.sharepoint.com'
export SP_SITE_PATH='/sites/FinOps'
export SP_LIBRARY_NAME='Documents'
export SP_FOLDER_PATH='PowerBI/OCI'      # must already exist
```

Two cautions:

- The secret lands in your shell history and process environment. Acceptable
  for a test; for anything recurring, pull it from **OCI Vault** instead.
- `env | grep MS_` prints the secret to the terminal. Don't run that on a
  shared screen.

---

## 5. GCC High / DoD tenants

Commercial endpoints will not work. Override all three:

```bash
export GRAPH_HOST='graph.microsoft.us'
export LOGIN_HOST='login.microsoftonline.us'
export GRAPH_SCOPE='https://graph.microsoft.us/.default'
```

Also confirm **egress from OCI Cloud Shell to the government Graph endpoint is
permitted**. Cross-cloud egress from an OC2/OC3 tenancy is frequently
restricted. If it is blocked, the fallback is to download the CSVs from Cloud
Shell and let a Power BI gateway collect them from SharePoint instead.

---

## 6. Verify before running the pipeline

### Token request

```bash
curl -s -X POST \
  "https://${LOGIN_HOST:-login.microsoftonline.com}/$MS_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$MS_CLIENT_ID" \
  -d "client_secret=$MS_CLIENT_SECRET" \
  -d "scope=${GRAPH_SCOPE:-https://graph.microsoft.com/.default}" \
  -d "grant_type=client_credentials" \
| python3 -c 'import json,sys; print("token OK" if json.load(sys.stdin).get("access_token") else "FAILED")'
```

`token OK` means `MS_TENANT_ID`, `MS_CLIENT_ID`, and `MS_CLIENT_SECRET` are
correct.

### Site resolution

```bash
TOKEN=$(curl -s -X POST \
  "https://${LOGIN_HOST:-login.microsoftonline.com}/$MS_TENANT_ID/oauth2/v2.0/token" \
  -d "client_id=$MS_CLIENT_ID" -d "client_secret=$MS_CLIENT_SECRET" \
  -d "scope=${GRAPH_SCOPE:-https://graph.microsoft.com/.default}" \
  -d "grant_type=client_credentials" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://${GRAPH_HOST:-graph.microsoft.com}/v1.0/sites/${SP_HOSTNAME}:${SP_SITE_PATH}" \
| python3 -m json.tool | head -20
```

A JSON object with an `id` means the site resolved. A 403 here means the
per-site `Sites.Selected` grant (section 3) was not done.

---

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `token OK` fails / `invalid_client` | Wrong `MS_CLIENT_SECRET`, or it expired |
| `AADSTS700016` | Wrong `MS_CLIENT_ID`, or app is in a different tenant |
| 403 resolving the site | `Sites.Selected` granted but per-site grant missing |
| 404 resolving the site | Wrong `SP_HOSTNAME` or `SP_SITE_PATH` |
| "document library not found" | `SP_LIBRARY_NAME` doesn't match the display name |
| "folder does not exist" | Create `SP_FOLDER_PATH` in the library first |
| Worked for weeks, now fails at token | Client secret expired |
| Timeouts / connection refused (Gov) | Cross-cloud egress blocked; use a gateway |

---

## 8. Power BI connection

Once files are uploading:

1. Power BI Desktop → **Get data → SharePoint folder**
2. Site URL: `https://contoso.sharepoint.com/sites/FinOps`
3. Filter `Folder Path` to your `SP_FOLDER_PATH`
4. Filter `Name` to the stable filenames the pipeline writes
5. Combine & transform, then publish

The pipeline always overwrites the same stable filenames, so the Power BI query
never has to chase a changing name.

---

## 9. Operational notes

- **Secret rotation** is the most likely future breakage. Track the expiry;
  move to OCI Vault or certificate auth for recurring runs.
- **Least privilege**: `Sites.Selected` + per-site `write` is the minimum that
  works. Don't settle for `Sites.ReadWrite.All` unless your security team
  requires it for another reason.
- The pipeline's only write operation is uploading/overwriting CSVs in the one
  configured folder. All OCI-side operations are read-only.
