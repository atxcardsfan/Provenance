//
//  ConsoleGamesView.swift
//  Provenance
//
//  Created by Ian Clawson on 1/22/22.
//  Copyright © 2022 Provenance Emu. All rights reserved.
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI
import RealmSwift
import PVLibrary
import PVThemes
import PVUIBase
import PVRealm
import PVSettings

// TODO: might be able to reuse this view for collections

struct ConsoleGamesFilterModeFlags: OptionSet {
    let rawValue: Int

    static let played = ConsoleGamesFilterModeFlags(rawValue: 1 << 0)
    static let neverPlayed = ConsoleGamesFilterModeFlags(rawValue: 1 << 1)
    static let recentlyImported = ConsoleGamesFilterModeFlags(rawValue: 1 << 2)
    static let recentlyPlayed = ConsoleGamesFilterModeFlags(rawValue: 1 << 3)
}

private struct SystemMoveState: Identifiable {
    var id: String { game.id }
    let game: PVGame
    var isPresenting: Bool = true
}

struct ConsoleGamesView: SwiftUI.View, GameContextMenuDelegate {

    @ObservedObject var viewModel: PVRootViewModel
    @ObservedRealmObject var console: PVSystem
    weak var rootDelegate: PVRootDelegate?

    let gamesForSystemPredicate: NSPredicate

    @ObservedResults(
        PVGame.self,
        sortDescriptor: SortDescriptor(keyPath: #keyPath(PVGame.title), ascending: false)
    ) var games

    @ObservedResults(PVRecentGame.self) var recentlyPlayedGames
    @ObservedResults(PVGame.self) var favorites
    @ObservedResults(PVGame.self) var mostPlayed

    @ObservedResults(
        PVSaveState.self,
        sortDescriptor: SortDescriptor(keyPath: #keyPath(PVSaveState.date), ascending: false)
    ) var recentSaveStates

    @ObservedObject private var themeManager = ThemeManager.shared

    @State private var gameLibraryItemsPerRow: Int = 4
    @Default(.gameLibraryScale) private var gameLibraryScale

    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var gameToUpdateCover: PVGame?
    @State private var showingRenameAlert = false
    @State private var gameToRename: PVGame?
    @State private var newGameTitle = ""
    @FocusState private var renameTitleFieldIsFocused: Bool

    @Default(.showRecentSaveStates) private var showRecentSaveStates
    @Default(.showFavorites) private var showFavorites
    @Default(.showRecentGames) private var showRecentGames

    @State private var systemMoveState: SystemMoveState?

    init(console: PVSystem, viewModel: PVRootViewModel, rootDelegate: PVRootDelegate? = nil) {
        self.console = console
        self.viewModel = viewModel
        self.rootDelegate = rootDelegate
        self.gamesForSystemPredicate = NSPredicate(format: "systemIdentifier == %@", argumentArray: [console.identifier])

        let recentlyPlayedPredicate = NSPredicate(format: "game.systemIdentifier == %@", argumentArray: [console.identifier])
        let favoritesPredicate = NSPredicate(format: "\(#keyPath(PVGame.isFavorite)) == %@ AND systemIdentifier == %@", NSNumber(value: true), console.identifier)
        let mostPlayedPredicate = NSPredicate(format: "systemIdentifier == %@", argumentArray: [console.identifier])
        let saveStatesPredicate = NSPredicate(format: "game.systemIdentifier == %@", argumentArray: [console.identifier])

        _recentlyPlayedGames = ObservedResults(PVRecentGame.self,
                                               filter: recentlyPlayedPredicate,
                                               sortDescriptor: SortDescriptor(keyPath: #keyPath(PVRecentGame.lastPlayedDate), ascending: false))
        _favorites = ObservedResults(PVGame.self,
                                     filter: favoritesPredicate,
                                     sortDescriptor: SortDescriptor(keyPath: #keyPath(PVGame.title), ascending: false))
        _mostPlayed = ObservedResults(PVGame.self,
                                      filter: mostPlayedPredicate,
                                      sortDescriptor: SortDescriptor(keyPath: #keyPath(PVGame.playCount), ascending: false))
        _recentSaveStates = ObservedResults(PVSaveState.self,
                                            filter: saveStatesPredicate,
                                            sortDescriptor: SortDescriptor(keyPath: #keyPath(PVSaveState.date), ascending: false))
    }

    var body: some SwiftUI.View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                displayOptionsView()
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            continueSection()
                            favoritesSection()
                            recentlyPlayedSection()
                            gamesSection()
                            BiosesView(console: console)
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 44)
                    }.refreshable {
                        ILOG("Refreshing game library")
                        await AppState.shared.libraryUpdatesController?.importROMDirectories()
                    }
                }
            }
            .edgesIgnoringSafeArea(.bottom)
            #if !os(tvOS)
            .gesture(magnificationGesture())
            #endif
            .onAppear {
                adjustZoomLevel(for: gameLibraryScale)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            #if !os(tvOS)
            imagePickerView()
            #endif
        }
        .alert("Rename Game", isPresented: $showingRenameAlert) {
            renameAlertView()
        } message: {
            Text("Enter a new name for \(gameToRename?.title ?? "")")
        }
        .sheet(item: $systemMoveState) { state in
            SystemPickerView(
                game: state.game,
                isPresented: Binding(
                    get: { state.isPresenting },
                    set: { newValue in
                        if !newValue {
                            systemMoveState = nil
                        }
                    }
                )
            )
        }
    }

    // MARK: - View Components

    private func displayOptionsView() -> some View {
        GamesDisplayOptionsView(
            sortAscending: viewModel.sortGamesAscending,
            isGrid: viewModel.viewGamesAsGrid,
            toggleFilterAction: { self.rootDelegate?.showUnderConstructionAlert() },
            toggleSortAction: { viewModel.sortGamesAscending.toggle() },
            toggleViewTypeAction: { viewModel.viewGamesAsGrid.toggle() }
        )
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private func continueSection() -> some View {
        Group {
            if showRecentSaveStates && hasRecentSaveStates {
                HomeContinueSection(rootDelegate: rootDelegate, consoleIdentifier: console.identifier)
                HomeDividerView()
            }
        }
    }

    private func favoritesSection() -> some View {
        Group {
            if showFavorites && hasFavorites {
                HomeSection(title: "Favorites") {
                    ForEach(favoritesArray, id: \.self) { favorite in
                        GameItemView(game: favorite, constrainHeight: true) {
                            loadGame(favorite)
                        }
                        .contextMenu { GameContextMenu(game: favorite, rootDelegate: rootDelegate, contextMenuDelegate: self) }
                    }
                }
                .frame(height: 150)
                HomeDividerView()
            }
        }
    }

    private func recentlyPlayedSection() -> some View {
        Group {
            if showRecentGames && hasRecentlyPlayedGames {
                HomeSection(title: "Recently Played") {
                    ForEach(recentlyPlayedGamesArray, id: \.self) { game in
                        GameItemView(game: game, constrainHeight: true) {
                            loadGame(game)
                        }
                        .contextMenu { GameContextMenu(game: game, rootDelegate: rootDelegate, contextMenuDelegate: self) }
                    }
                }
                .frame(height: 150)
                HomeDividerView()
            }
        }
    }

    private func gamesSection() -> some View {
        Group {
            if games.isEmpty && AppState.shared.isSimulator {
                let fakeGames = PVGame.mockGenerate(systemID: console.identifier)
                if viewModel.viewGamesAsGrid {
                    showGamesGrid(fakeGames)
                } else {
                    showGamesList(fakeGames)
                }
            } else {
                if viewModel.viewGamesAsGrid {
                    showGamesGrid(filteredAndSortedGames())
                } else {
                    showGamesList(filteredAndSortedGames())
                }
            }
        }
    }

#if !os(tvOS)
    private func imagePickerView() -> some View {
        ImagePicker(sourceType: .photoLibrary) { image in
            if let game = gameToUpdateCover {
                saveArtwork(image: image, forGame: game)
            }
            gameToUpdateCover = nil
            showImagePicker = false
        }
    }
#endif

    private func renameAlertView() -> some View {
        Group {
            TextField("New name", text: $newGameTitle)
                .onSubmit { submitRename() }
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)

            Button("Cancel", role: .cancel) { showingRenameAlert = false }
            Button("OK") { submitRename() }
        }
    }

    // MARK: - Helper Methods

    func filteredAndSortedGames() -> Results<PVGame> {
        return games
            .filter(gamesForSystemPredicate)
            .sorted(by: [
                SortDescriptor(keyPath: #keyPath(PVGame.title), ascending: viewModel.sortGamesAscending)
            ])
    }

    private var hasRecentSaveStates: Bool {
        !recentSaveStates.filter("game.systemIdentifier == %@", console.identifier).isEmpty
    }

    private var hasFavorites: Bool {
        !favorites.filter("systemIdentifier == %@", console.identifier).isEmpty
    }

    private var favoritesArray: [PVGame] {
        Array(favorites.filter("systemIdentifier == %@", console.identifier))
    }

    private var hasRecentlyPlayedGames: Bool {
        !recentlyPlayedGames.isEmpty
    }

    private var recentlyPlayedGamesArray: [PVGame] {
        recentlyPlayedGames.compactMap { $0.game }
    }

    private func loadGame(_ game: PVGame) {
        Task.detached { @MainActor in
            await rootDelegate?.root_load(game, sender: self, core: nil, saveState: nil)
        }
    }

    var itemsPerRow: Int {
        let roundedScale = Int(gameLibraryScale.rounded())
        // If games is less than count, just use the games to fill the row.
        // also don't go below 0
        let count: Int
        if AppState.shared.isSimulator {
            count = max(0,roundedScale )
        } else {
            count = min(max(0, roundedScale), games.count)
        }
        return count
    }

    private func showGamesGrid(_ games: [PVGame]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: itemsPerRow)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(games, id: \.self) { game in
                GameItemView(game: game, constrainHeight: false) {
                    loadGame(game)
                }
                .contextMenu { GameContextMenu(game: game, rootDelegate: rootDelegate, contextMenuDelegate: self) }
            }
        }
        .padding(.horizontal, 10)
    }

    private func showGamesGrid(_ games: Results<PVGame>) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: itemsPerRow)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(games, id: \.self) { game in
                GameItemView(game: game, constrainHeight: false) {
                    loadGame(game)
                }
                .contextMenu { GameContextMenu(game: game, rootDelegate: rootDelegate, contextMenuDelegate: self) }
            }
        }
        .padding(.horizontal, 10)
    }

    private func showGamesList(_ games: [PVGame]) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(games, id: \.self) { game in
                GameItemView(game: game, constrainHeight: false, viewType: .row) {
                    loadGame(game)
                }
                .contextMenu { GameContextMenu(game: game, rootDelegate: rootDelegate, contextMenuDelegate: self) }
            }
        }
    }

    private func showGamesList(_ games: Results<PVGame>) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(games, id: \.self) { game in
                GameItemView(game: game, constrainHeight: false, viewType: .row) {
                    loadGame(game)
                }
                .contextMenu { GameContextMenu(game: game, rootDelegate: rootDelegate, contextMenuDelegate: self) }
            }
        }
    }

    private func calculateGridItemSize() -> CGFloat {
        let numberOfItemsPerRow: CGFloat = CGFloat(gameLibraryScale)
        let totalSpacing: CGFloat = 10 * (numberOfItemsPerRow - 1)
        let availableWidth = UIScreen.main.bounds.width - totalSpacing - 20
        return availableWidth / numberOfItemsPerRow
    }

    private func adjustZoomLevel(for magnification: Float) {
        gameLibraryItemsPerRow = calculatedZoomLevel(for: magnification)
    }

    private func calculatedZoomLevel(for magnification: Float) -> Int {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let defaultZoomLevel = isIPad ? 8 : 4

        // Handle invalid magnification values
        guard !magnification.isNaN && !magnification.isInfinite else {
            return defaultZoomLevel
        }

        // Calculate the target zoom level based on magnification
        let targetZoomLevel = Float(defaultZoomLevel) / magnification

        // Round to the nearest even number
        let roundedZoomLevel = round(targetZoomLevel / 2) * 2

        // Clamp the value between 2 and 16
        let clampedZoomLevel = max(2, min(16, roundedZoomLevel))

        return Int(clampedZoomLevel)
    }

#if !os(tvOS)
    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                adjustZoomLevel(for: Float(value))
            }
            .onEnded { _ in
                // TODO: What to do here?
            }
    }
    #endif

    // MARK: - Rename Methods

    func gameContextMenu(_ menu: GameContextMenu, didRequestRenameFor game: PVGame) {
        gameToRename = game.freeze()
        newGameTitle = game.title
        showingRenameAlert = true
    }

    private func submitRename() {
        if !newGameTitle.isEmpty, let frozenGame = gameToRename, newGameTitle != frozenGame.title {
            do {
                guard let thawedGame = frozenGame.thaw() else {
                    throw NSError(domain: "ConsoleGamesView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to thaw game object"])
                }
                RomDatabase.sharedInstance.renameGame(thawedGame, toTitle: newGameTitle)
                rootDelegate?.showMessage("Game renamed successfully.", title: "Success")
            } catch {
                DLOG("Failed to rename game: \(error.localizedDescription)")
                rootDelegate?.showMessage("Failed to rename game: \(error.localizedDescription)", title: "Error")
            }
        } else if newGameTitle.isEmpty {
            rootDelegate?.showMessage("Cannot set a blank title.", title: "Error")
        }
        showingRenameAlert = false
        gameToRename = nil
    }

    // MARK: - Image Picker Methods

    func gameContextMenu(_ menu: GameContextMenu, didRequestChooseCoverFor game: PVGame) {
        gameToUpdateCover = game
        showImagePicker = true
    }

    private func saveArtwork(image: UIImage, forGame game: PVGame) {
        DLOG("GameContextMenu: Attempting to save artwork for game: \(game.title)")

        let uniqueID = UUID().uuidString
        let key = "artwork_\(game.md5)_\(uniqueID)"
        DLOG("Generated key for image: \(key)")

        do {
            DLOG("Attempting to write image to disk")
            try PVMediaCache.writeImage(toDisk: image, withKey: key)
            DLOG("Image successfully written to disk")

            DLOG("Attempting to update game's customArtworkURL")
            try RomDatabase.sharedInstance.writeTransaction {
                let thawedGame = game.thaw()
                DLOG("Game thawed: \(thawedGame?.title ?? "Unknown")")
                thawedGame?.customArtworkURL = key
                DLOG("Game's customArtworkURL updated to: \(key)")
            }
            DLOG("Database transaction completed successfully")
            rootDelegate?.showMessage("Artwork has been saved for \(game.title).", title: "Artwork Saved")

            DLOG("Attempting to verify image retrieval")
            PVMediaCache.shareInstance().image(forKey: key) { retrievedKey, retrievedImage in
                if let retrievedImage = retrievedImage {
                    DLOG("Successfully retrieved saved image for key: \(retrievedKey)")
                    DLOG("Retrieved image size: \(retrievedImage.size)")
                } else {
                    DLOG("Failed to retrieve saved image for key: \(retrievedKey)")
                }
            }
        } catch {
            DLOG("Failed to set custom artwork: \(error.localizedDescription)")
            DLOG("Error details: \(error)")
            rootDelegate?.showMessage("Failed to set custom artwork for \(game.title): \(error.localizedDescription)", title: "Error")
        }
    }

    func gameContextMenu(_ menu: GameContextMenu, didRequestMoveToSystemFor game: PVGame) {
        DLOG("ConsoleGamesView: Received request to move game to system")
        let frozenGame = game.isFrozen ? game : game.freeze()
        systemMoveState = SystemMoveState(game: frozenGame)
    }
}

@available(iOS 14, tvOS 14, *)
struct ConsoleGamesView_Previews: PreviewProvider {
    static let console: PVSystem = ._rlmDefaultValue()
    static let viewModel: PVRootViewModel = .init()

    static var previews: some SwiftUI.View {
        ConsoleGamesView(console: console,
                         viewModel: viewModel,
                         rootDelegate: nil)
    }
}

struct BiosesView: View {
    let console: PVSystem

    var body: some View {
        VStack {
            GamesDividerView()
            ForEach(console.bioses, id: \.self) { bios in
                BiosRowView(bios: bios.warmUp())
                GamesDividerView()
            }
        }
    }
}

#endif
