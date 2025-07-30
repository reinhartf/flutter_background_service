import Flutter
import UIKit
import AVKit
import BackgroundTasks

public class SwiftFlutterBackgroundServicePlugin: FlutterPluginAppLifeCycleDelegate, FlutterPlugin  {
    public static var taskIdentifier = "dev.flutter.background.refresh"
    // For testing, run app, bring app to background to schedule the task
    // Pause debug in XCODE, then execute:
    // e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.flutter.background.refresh"]
    // in Outputs log after (lldb)
    // Resume debugger
    
    var mainChannel: FlutterMethodChannel? = nil
    
    public override func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        LogToFlutter.shared.log("[background_service] performFetchWithCompletionHandler")
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "background_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("Background handler is disabled")
            completionHandler(.noData)
            return true
        }
        
        // execute callback handle
        
        let worker = FlutterBackgroundFetchWorker(task: completionHandler)
        worker.onCompleted = {
            print("Background Fetch Completed")
        }
        worker.run()
        return true
    }
        
    public override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
        LogToFlutter.shared.log("[background_service] didFinishLaunchingWithOptions")
        UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        if #available(iOS 13.0, *) {
            SwiftFlutterBackgroundServicePlugin.registerTaskIdentifier(taskIdentifier: SwiftFlutterBackgroundServicePlugin.taskIdentifier)
        }
        
        return true
    }
    
    public func applicationDidEnterBackground(_ application: UIApplication) {
        if #available(iOS 13.0, *){
            SwiftFlutterBackgroundServicePlugin.scheduleAppRefresh()
        }
    }
    
    @available(iOS 13.0, *)
    public static func registerTaskIdentifier(taskIdentifier: String) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    @available(iOS 13.0, *)
    private static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: SwiftFlutterBackgroundServicePlugin.taskIdentifier)
       request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 60 * 60)
            
       do {
           // cancel old schedule
           BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SwiftFlutterBackgroundServicePlugin.taskIdentifier)
           
          try BGTaskScheduler.shared.submit(request)
       } catch {
          print("Could not schedule app refresh: \(error)")
       }
    }
    
    @available(iOS 13.0, *)
    private static func handleAppRefresh(task: BGAppRefreshTask) {
        LogToFlutter.shared.log("[background_service] handleAppRefresh")
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "background_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("Background handler is disabled")
            return
        }
        
        let operationQueue = OperationQueue()
        let operation = FlutterBackgroundRefreshAppOperation(
            task: task
        )

        operation.completionBlock = {
            scheduleAppRefresh()
        }

        operationQueue.addOperation(operation)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "id.flutter/background_service_ios",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec())
        
        let channel2 = FlutterEventChannel(name: "com.lifeq.companion/flutter_background_service_to_flutter_logs", binaryMessenger: registrar.messenger())    
        channel2.setStreamHandler(LogToFlutterStreamHandler())

        let instance = SwiftFlutterBackgroundServicePlugin()
        instance.mainChannel = channel
        
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }
    
    private func autoStart(isForeground: Bool) {
        let defaults = UserDefaults.standard
        let autoStart = defaults.bool(forKey: "auto_start")
        if (autoStart) {
            self.runForegroundWorker()
        }
    }
    
    fileprivate var foregroundWorker: FlutterForegroundWorker? = nil
    private func runForegroundWorker(){
        if (foregroundWorker != nil){
            return
        }
        
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "foreground_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("Foreground service is disabled")
            return
        }
        
        foregroundWorker = FlutterForegroundWorker(mainChannel: self.mainChannel!)
        foregroundWorker?.onTerminated = {
            self.foregroundWorker = nil
        }
        foregroundWorker?.run()
    }
    
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "configure") {
            let args = call.arguments as? Dictionary<String, Any>
            let foregroundCallbackHandleID = args?["foreground_handle"] as? NSNumber
            let backgroundCallbackHandleID = args?["background_handle"] as? NSNumber
            let autoStart = args?["auto_start"] as? Bool ?? true
            
            let defaults = UserDefaults.standard
            defaults.set(foregroundCallbackHandleID?.int64Value, forKey: "foreground_callback_handle")
            defaults.set(backgroundCallbackHandleID?.int64Value, forKey: "background_callback_handle")
            defaults.set(autoStart, forKey: "auto_start")
            
            if (autoStart && (foregroundCallbackHandleID != nil)){
                self.autoStart(isForeground: true)
            }
            
            result(true)
            return
        }
        
        if (call.method == "start") {
            runForegroundWorker()
            result(true)
        }
        
        if (call.method == "sendData") {
            self.foregroundWorker?.onReceivedData(data: call.arguments)
            result(true);
        }
                
        if (call.method == "isServiceRunning") {
            let value = self.foregroundWorker != nil;
            result(value);
            return;
        }
    }
}

@available(iOS 13, *)
class FlutterBackgroundRefreshAppOperation: Operation {
    var task: BGAppRefreshTask
    fileprivate var worker: FlutterBackgroundRefreshAppWorker?
    
    init(task: BGAppRefreshTask) {
        self.task = task
    }
    
    override func main() {
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.async {
            self.worker = FlutterBackgroundRefreshAppWorker(task: self.task)
            self.worker?.onCompleted = {
                semaphore.signal()
            }
            
            self.task.expirationHandler = {
                self.worker?.cancel()
            }
                        
            self.worker?.run()
        }
        
        semaphore.wait()
    }
}

typealias VoidInputVoidReturnBlock = () -> Void

@available(iOS 13, *)
private class FlutterBackgroundRefreshAppWorker {
    let entrypointName = "backgroundEntrypoint"
    let uri = "package:flutter_background_service_ios/flutter_background_service_ios.dart"
    let engine = FlutterEngine(name: "BackgroundHandleFlutterEngine")
    
    var onCompleted: VoidInputVoidReturnBlock?
    var task: BGAppRefreshTask
    var channel: FlutterMethodChannel?
    
    init(task: BGAppRefreshTask){
        LogToFlutter2.shared.log("[background_service] BackgroundRefreshAppWorker init")
        self.task = task
    }
    
    public func run() {
        LogToFlutter2.shared.log("[background_service] BackgroundRefreshAppWorker run")
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "background_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("No callback handle for background")
            LogToFlutter2.shared.log("[background_service] BackgroundRefreshAppWorker no callback handle for background")
            return
        }
        
        let isRunning = engine.run(withEntrypoint: entrypointName, libraryURI: uri, initialRoute: nil, entrypointArgs: [String(callbackHandle!)])
        
        if (isRunning){
            LogToFlutter2.shared.log("[background_service] BackgroundRefreshAppWorker engine running")
            FlutterBackgroundServicePlugin.register(engine)
            
            let binaryMessenger = engine.binaryMessenger
            channel = FlutterMethodChannel(name: "id.flutter/background_service_ios_bg", binaryMessenger: binaryMessenger, codec: FlutterJSONMethodCodec())
            channel?.setMethodCallHandler(handleMethodCall)

            let logChannel = FlutterEventChannel(name: "com.lifeq.companion/app_fresh_task_to_flutter_logs", binaryMessenger: binaryMessenger)
            logChannel.setStreamHandler(LogToFlutterStreamHandler2())
        }
    }
    
    public func cancel(){
        DispatchQueue.main.async {
            self.engine.destroyContext()
        }
        
        self.task.setTaskCompleted(success: false)
        self.onCompleted?()
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "setBackgroundFetchResult") {
            let result = call.arguments as? Bool ?? false
            self.task.setTaskCompleted(success: result)
            
            DispatchQueue.main.async {
                self.engine.destroyContext()
            }
            
            self.onCompleted?()
            print("Flutter Background Service Completed")
        }
    }
}

private class FlutterBackgroundFetchWorker {
    let entrypointName = "backgroundEntrypoint"
    let uri = "package:flutter_background_service_ios/flutter_background_service_ios.dart"
    let engine = FlutterEngine(name: "BackgroundHandleFlutterEngine")
    
    var onCompleted: VoidInputVoidReturnBlock?
    var task: ((UIBackgroundFetchResult) -> Void)
    var channel: FlutterMethodChannel?
    
    init(task: @escaping (UIBackgroundFetchResult) -> Void){
        self.task = task
    }
    
    public func run() {
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "background_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("No callback handle for background")
            return
        }
        
        let isRunning = engine.run(withEntrypoint: entrypointName, libraryURI: uri, initialRoute: nil, entrypointArgs: [String(callbackHandle!)])
        
        if (isRunning){
            FlutterBackgroundServicePlugin.register(engine)
            
            let binaryMessenger = engine.binaryMessenger
            channel = FlutterMethodChannel(name: "id.flutter/background_service_ios_bg", binaryMessenger: binaryMessenger, codec: FlutterJSONMethodCodec())
            channel?.setMethodCallHandler(handleMethodCall)
        }
    }
    
    public func cancel(){
        self.engine.destroyContext()
        self.task(.failed)
        self.onCompleted?()
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "setBackgroundFetchResult") {
            let result = call.arguments as? Bool ?? false
            
            if (result) {
                self.task(.newData)
            } else {
                self.task(.noData)
            }
            
            self.engine.destroyContext()
            self.onCompleted?()
            print("Flutter Background Service Completed")
        }
    }
}

private class FlutterForegroundWorker {
    let entrypointName = "foregroundEntrypoint"
    let uri = "package:flutter_background_service_ios/flutter_background_service_ios.dart"
    let engine = FlutterEngine(name: "ForegroundHandleFlutterEngine")
    
    var channel: FlutterMethodChannel?
    var mainChannel: FlutterMethodChannel
    var onTerminated: VoidInputVoidReturnBlock?

    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    init(mainChannel: FlutterMethodChannel){
        LogToFlutter3.shared.log("[background_service] FlutterForegrounWorker init")
        self.mainChannel = mainChannel
    }
    
    public func run() {
        LogToFlutter3.shared.log("[background_service] FlutterForegrounWorker run")
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "foreground_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("No callback handle for foreground")
            return
        }
        
        let isRunning = engine.run(withEntrypoint: entrypointName, libraryURI: uri, initialRoute: nil, entrypointArgs: [String(callbackHandle!)])
        
        if (isRunning){
            LogToFlutter3.shared.log("[background_service] FlutterForegrounWorker isRunning")
            FlutterBackgroundServicePlugin.register(engine)
            
            let binaryMessenger = engine.binaryMessenger
            channel = FlutterMethodChannel(name: "id.flutter/background_service_ios_bg", binaryMessenger: binaryMessenger, codec: FlutterJSONMethodCodec())
            channel?.setMethodCallHandler(handleMethodCall)

            let logChannel = FlutterEventChannel(name: "com.lifeq.companion/foreground_worker_to_flutter_logs", binaryMessenger: binaryMessenger)
            logChannel.setStreamHandler(LogToFlutterStreamHandler3())
        }
    }
    
    public func onReceivedData(data: Any?) {
        self.channel?.invokeMethod("onReceiveData", arguments: data)
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "sendData") {
            self.mainChannel.invokeMethod("onReceiveData", arguments: call.arguments)
            result(true);
            return;
        }
        
        if (call.method == "stopService") {
            self.engine.destroyContext()
            result(true)
            self.onTerminated?()
            return;
        }

        if (call.method == "beginBackgroundTask") {
            LogToFlutter3.shared.log("[background_service] beginBackgroundTask")
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask (withName: "Perform background BLE data sync") {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                self.backgroundTaskID = .invalid
            }
            let remainingTime = UIApplication.shared.backgroundTimeRemaining
            result(remainingTime)
            return
        }

        if (call.method == "endBackgroundTask") {
            LogToFlutter3.shared.log("[background_service] endBackgroundTask")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
            result(nil)
            return
        }
    }
}

class LogToFlutter {
    static let shared = LogToFlutter()

    private var sink: FlutterEventSink?
    private var buffer: [String] = []

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    func setSink(_ sink: FlutterEventSink?) {
        self.sink = sink

        // Flush any buffered messages
        for message in buffer {
            sink?(message)
        }
        buffer.removeAll()
    }

    func log(_ message: String) {
        if let sink = sink {
            sink(message)
        } else {
            let timestamp = dateFormatter.string(from: Date())
            let timestampedMessage = "[\(timestamp)] \(message)"
            buffer.append(timestampedMessage) // Store for later
        }
    }
}

class LogToFlutterStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        LogToFlutter.shared.setSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        LogToFlutter.shared.setSink(nil)
        return nil
    }
}

class LogToFlutter2 {
    static let shared = LogToFlutter2()

    private var sink: FlutterEventSink?
    private var buffer: [String] = []

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    func setSink(_ sink: FlutterEventSink?) {
        self.sink = sink

        // Flush any buffered messages
        for message in buffer {
            sink?(message)
        }
        buffer.removeAll()
    }

    func log(_ message: String) {
        if let sink = sink {
            sink(message)
        } else {
            let timestamp = dateFormatter.string(from: Date())
            let timestampedMessage = "[\(timestamp)] \(message)"
            buffer.append(timestampedMessage) // Store for later
        }
    }
}

class LogToFlutterStreamHandler2: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        LogToFlutter2.shared.setSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        LogToFlutter2.shared.setSink(nil)
        return nil
    }
}

class LogToFlutter3 {
    static let shared = LogToFlutter3()

    private var sink: FlutterEventSink?
    private var buffer: [String] = []

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    func setSink(_ sink: FlutterEventSink?) {
        self.sink = sink

        // Flush any buffered messages
        for message in buffer {
            sink?(message)
        }
        buffer.removeAll()
    }

    func log(_ message: String) {
        if let sink = sink {
            sink(message)
        } else {
            let timestamp = dateFormatter.string(from: Date())
            let timestampedMessage = "[\(timestamp)] \(message)"
            buffer.append(timestampedMessage) // Store for later
        }
    }
}

class LogToFlutterStreamHandler3: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        LogToFlutter3.shared.setSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        LogToFlutter3.shared.setSink(nil)
        return nil
    }
}
