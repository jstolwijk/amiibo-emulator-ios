//
//  Amiibo_EmulatorApp.swift
//  Amiibo Emulator
//
//  Created by Jesse Stolwijk on 15/06/2026.
//

import SwiftUI

@main
struct Amiibo_EmulatorApp: App {
    @StateObject private var bluetoothManager = ChameleonBluetoothManager()
    @StateObject private var databaseViewModel = AmiiboDatabaseViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(
                bluetoothManager: bluetoothManager,
                databaseViewModel: databaseViewModel
            )
        }
    }
}
