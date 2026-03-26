import 'package:flutter/material.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome'),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: () async {}),
        ],
      ),
      body: const Center(child: Text('You are logged in!')),
    );
  }
}
