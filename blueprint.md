# Project Overview

This project is a Flutter application that uses Firebase for authentication. It allows users to sign in, sign up, and reset their password. Once a user is signed in, they are taken to a welcome screen.

## Features

* **Email and password authentication:** Users can sign in and sign up with their email and password.
* **Password reset:** Users can reset their password if they have forgotten it.
* **Authentication state management:** The application correctly handles the authentication state of the user, showing the welcome screen if the user is signed in and the login screen if they are not.

## Project Structure

*   `lib/main.dart`: The main entry point of the application.
*   `lib/auth_service.dart`: A service that handles all the authentication logic.
*   `lib/auth_wrapper.dart`: A widget that wraps the entire application and shows the correct screen based on the user's authentication state.
*   `lib/login_screen.dart`: The screen where users can sign in.
*   `lib/sign.dart`: The screen where users can sign up.
*   `lib/forgot.dart`: The screen where users can reset their password.
*   `lib/welcome.dart`: The screen that is shown to users when they are signed in.
