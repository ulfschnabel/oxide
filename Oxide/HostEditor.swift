import OxideKit
import SwiftUI

/// Add a computer, or edit one.
struct HostEditor: View {
    let library: HostLibrary
    let host: SavedHost?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var passwordKind: PasswordKind = .oneTime
    @State private var password = ""
    @State private var rememberPassword = true
    @State private var passwordChanged = false
    @State private var error: String?
    @FocusState private var focus: Field?
    /// The password field is UIKit's: its focus is plain state, since
    /// `@FocusState` drops a value no SwiftUI field takes, which would take
    /// the focus away from it again the moment it's clicked.
    @State private var passwordFocused = false
    @State private var formHeight: CGFloat = 0

    private enum Field { case name, address }

    private var addressValid: Bool { HostAddress(address) != nil }
    private var hadPassword: Bool { host.map(library.hasPassword) ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Office PC"))
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .address }
                    TextField("Address", text: $address, prompt: Text("192.168.1.20 or pc.local:21118"))
                        .focused($focus, equals: .address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(passwordKind == .permanent ? .next : .done)
                        .onSubmit { if passwordKind == .permanent { passwordFocused = true } }
                } footer: {
                    if !address.isEmpty && !addressValid {
                        Text("Use a host name or IP address, optionally with :port (1–65535).")
                            .foregroundStyle(.red)
                    } else {
                        Text("The computer's address on your network or VPN. RustDesk's direct IP port is 21118 unless you changed it.")
                    }
                }

                Section {
                    Picker("Password", selection: $passwordKind) {
                        Text("One-time").tag(PasswordKind.oneTime)
                        Text("Permanent").tag(PasswordKind.permanent)
                    }
                    .pickerStyle(.segmented)
                    if passwordKind == .permanent {
                        HostPasswordField(placeholder: hadPassword && !passwordChanged ? "Saved — type to change" : "Password",
                                          text: $password, isFocused: $passwordFocused,
                                          onSubmit: { passwordFocused = false })
                            .onChange(of: password) { passwordChanged = true }
                        Toggle("Remember password", isOn: $rememberPassword)
                    }
                } footer: {
                    switch passwordKind {
                    case .oneTime:
                        Text("RustDesk's default. It shows a one-time password on that computer and makes a new one after each connection. Oxide asks for it every time you connect.")
                    case .permanent:
                        Text("The password set in RustDesk on that computer (Settings → Security → Set permanent password). It's kept in your keychain, synced to your other devices through iCloud Keychain, and only used to log in.")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .measuringHeight($formHeight)
            // The password field goes away with One-time: its focus with it.
            .onChange(of: passwordKind) { passwordFocused = false }
            .navigationTitle(host == nil ? "Add Computer" : "Edit Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                        .disabled(!addressValid)
                }
            }
            .onAppear {
                if let host {
                    name = host.name
                    address = host.address
                    passwordKind = host.passwordKind
                    rememberPassword = hadPassword
                    passwordChanged = false
                } else {
                    focus = .name
                }
            }
        }
        .fittedSheet(height: formHeight)
    }

    private func save() {
        do {
            if let host {
                let newPassword: String? = !rememberPassword ? "" : (passwordChanged ? password : nil)
                try library.update(host, name: name, address: address, passwordKind: passwordKind, password: newPassword)
            } else {
                try library.add(name: name, address: address, passwordKind: passwordKind,
                                password: rememberPassword ? password : nil)
            }
            dismiss()
        } catch HostListError.invalidAddress {
            self.error = "That address isn't valid."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Asked when a computer has no saved password, or the saved one was wrong.
struct PasswordPrompt: View {
    let host: SavedHost
    let wrong: Bool
    var onConnect: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Bool
    /// See `HostEditor.passwordFocused`.
    @State private var passwordFocused = false
    @State private var formHeight: CGFloat = 0

    private var oneTime: Bool { host.passwordKind == .oneTime }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if oneTime {
                        // Read off the other screen and useless once used:
                        // shown in the clear, never remembered.
                        TextField("One-time password", text: $password)
                            .font(.title2.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .submitLabel(.go)
                            .focused($focused)
                            .onSubmit(connect)
                    } else {
                        HostPasswordField(placeholder: "Password", text: $password,
                                          isFocused: $passwordFocused,
                                          onSubmit: connect)
                        Toggle("Remember password", isOn: $remember)
                    }
                } header: {
                    if wrong {
                        Label(oneTime ? "That one-time password didn't work" : "The password was wrong",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    if oneTime {
                        Text(wrong
                             ? "It changes after every connection, and after 10 wrong tries. Check the current one in RustDesk on \(host.displayName)."
                             : "Shown in RustDesk on \(host.displayName), next to the computer's ID. It changes after every connection.")
                    } else {
                        Text("The RustDesk permanent password of \(host.displayName).")
                    }
                }
            }
            .measuringHeight($formHeight)
            .navigationTitle(host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", systemImage: "arrow.right") { connect() }
                        .disabled(password.isEmpty)
                }
            }
            .onAppear { if oneTime { focused = true } else { passwordFocused = true } }
        }
        .presentationDetents([.medium])
        .fittedSheet(height: formHeight)
    }

    private func connect() {
        let password = oneTime ? password.trimmingCharacters(in: .whitespaces) : password
        guard !password.isEmpty else { return }
        onConnect(password, remember && !oneTime)
    }
}

extension View {
    /// The height of a form's content (with its insets, the navigation bar
    /// included), for `fittedSheet`.
    func measuringHeight(_ height: Binding<CGFloat>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { g in
            g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom
        } action: { _, new in
            height.wrappedValue = new
        }
    }

    /// A sheet as tall as its form, where sheets are free-sized (a Mac, an
    /// iPad): a fixed form-sheet size shows a scroll bar once a section
    /// grows. iPhone sheets keep their detents.
    func fittedSheet(height: CGFloat) -> some View {
        frame(idealHeight: height > 0 ? height : nil)
            .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    }
}

/// A secure text field that iOS doesn't take for an account login: a remote
/// computer's password is kept by Oxide, so "Save Password?" and password
/// AutoFill would only get in the way.
struct HostPasswordField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// SwiftUI's `.focused` doesn't reach a UIKit field, so focus is bridged here.
    @Binding var isFocused: Bool
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let field = ClearingField()
        field.isSecureTextEntry = true
        field.textContentType = .oneTimeCode
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.delegate = context.coordinator
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        field.placeholder = placeholder
        if field.text != text { field.text = text }
        context.coordinator.parent = self
        if isFocused != field.isFirstResponder {
            // After this update pass, and once the field is in a window.
            DispatchQueue.main.async {
                guard field.window != nil, self.isFocused != field.isFirstResponder else { return }
                if self.isFocused { field.becomeFirstResponder() } else { field.resignFirstResponder() }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// iOS offers "Save Password?" for what a secure field still holds when
    /// it leaves the screen; by then the value is in the binding, so empty it.
    final class ClearingField: UITextField {
        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil { text = "" }
            super.willMove(toWindow: newWindow)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: HostPasswordField

        init(_ parent: HostPasswordField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}
