PUSH NOTIFICATIONS FOR A CLOSED APP (optional, needs a free Firebase project)

1. Go to https://console.firebase.google.com -> Add project (name it Kanyatsi).
2. In the project: Add app -> Android. Package name must be exactly:
       com.kagando.kagando_akanyatsi_restaurant
3. Download google-services.json and put it in THIS folder:
       firebase/google-services.json        (then commit it to GitHub)
4. Firebase console -> Project settings -> Service accounts -> "Generate new private key".
   Open the downloaded .json file and copy ALL of its text.
5. Google Apps Script -> Project Settings (gear) -> Script properties -> Add property:
       Name:  FCM_SERVICE_ACCOUNT
       Value: (paste the whole json text)
6. In Apps Script run the function  setupSheets  once more and accept the new permission
   ("connect to an external service").  Then Deploy -> Manage deployments -> New version.
7. Build the app again. In the build log, the step
   "Enable push notifications for a closed app (optional)" must say  Push notifications ENABLED.

Without this folder's google-services.json the app still works. Notifications then appear while the app is
open or recently used, but not when it is fully closed.
