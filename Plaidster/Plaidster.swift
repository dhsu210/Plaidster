//
//  Plaidster.swift
//  Plaidster
//
//  Created by Willow Bellemore on 2016-01-13.
//  Copyright © 2016 Plaidster. All rights reserved.
//

import Foundation

public typealias LoggingFunction = (item: Any) -> (Void)

public enum PlaidProduct: String {
    case Connect = "connect"
    case Auth    = "auth"
}

public enum PlaidEnvironment {
    case Production
    case Development
}

public enum PlaidMFAType: String {
    case Questions = "questions"    // Question based MFA
    case List      = "list"         // List of device options for code based MFA
    case Device    = "device"       // Code sent to chosen device
}

public enum PlaidMFAResponseType {
    case Code
    case Question
    case DeviceType
    case DeviceMask
}

private func cocoaErrorFromException(exception: ErrorType) -> NSError {
    if let exception = exception as? PlaidErrorConvertible {
        return exception.cocoaError()
    } else {
        return PlaidsterError.UnknownException(exception: exception).cocoaError()
    }
}

private func throwPlaidsterError(code: Int?, _ message: String?) throws {
    if let code = code {
        switch code {
        case PlaidErrorCode.InstitutionDown: throw PlaidError.InstitutionDown
        case PlaidErrorCode.BadAccessToken: throw PlaidError.BadAccessToken
        case PlaidErrorCode.ItemNotFound: throw PlaidError.ItemNotFound
        default: throw PlaidError.GenericError(code, message)
        }
    }
}

public struct Plaidster {
    
    //
    // MARK: - Constants -
    //
    
    private static let DevelopmentBaseURL = "https://tartan.plaid.com/"
    private static let ProductionBaseURL = "https://api.plaid.com/"
    
    //
    // MARK: - Properties -
    //
    
    private let session = NSURLSession.sharedSession()
    private let clientID: String
    private let secret: String
    private let baseURL: String
    
    //
    // MARK: - Logging -
    //
    
    // Set to true to debugPrint all raw JSON responses from Plaid
    public var printRawConnections = false
    public var logger: LoggingFunction?
    public var rawConnectionsLogger: LoggingFunction?
    
    // Optionally change the default connection timeout of 60 seconds
    private static let defaultConnectionTimeout = 60.0
    public var connectionTimeout: NSTimeInterval = Plaidster.defaultConnectionTimeout
    
    //
    // MARK: - Initialisation -
    //
    
    public init(clientID: String, secret: String, mode: PlaidEnvironment, connectionTimeout: NSTimeInterval = Plaidster.defaultConnectionTimeout) {
        self.clientID = clientID
        self.secret = secret
        
        switch mode {
        case .Development:
            self.baseURL = Plaidster.DevelopmentBaseURL
        case .Production:
            self.baseURL = Plaidster.ProductionBaseURL
        }
        
        self.connectionTimeout = connectionTimeout
    }
    
    //
    // MARK: - Private Methods -
    //
    
    private func log(item: Any) {
        if let logger = logger {
            logger(item: item)
        } else {
            print(item)
        }
    }
    
    func dictionaryToString(value: AnyObject) -> String {
        guard NSJSONSerialization.isValidJSONObject(value) else { return "" }
        do {
            let data = try NSJSONSerialization.dataWithJSONObject(value, options: NSJSONWritingOptions(rawValue: 0))
            if let string = String(data: data, encoding: NSUTF8StringEncoding) {
                return string
            }
        } catch {
            log("Error serializing dictionary: \(error)")
        }
        
        return ""
    }
    
    static private let JSONDateFormatter = NSDateFormatter()
    static private var JSONDateFormatterToken: dispatch_once_t = 0
    func dateToJSONString(date: NSDate) -> String {
        dispatch_once(&Plaidster.JSONDateFormatterToken) {
            Plaidster.JSONDateFormatter.dateFormat = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'SSS'Z'"
        }
        
        return Plaidster.JSONDateFormatter.stringFromDate(date)
    }
    
    static private var printRequestDateFormatterToken: dispatch_once_t = 0
    static private let printRequestDateFormatter = NSDateFormatter()
    private func printRequest(request: NSURLRequest, responseData: NSData, function: String = #function) {
        dispatch_once(&Plaidster.printRequestDateFormatterToken) {
            Plaidster.printRequestDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        }
        
        if printRawConnections {
            let url = request.URL?.absoluteString ?? "Failed to decode URL"
            var body = ""
            if let HTTPBody = request.HTTPBody {
                if let HTTPBodyString = NSString(data: HTTPBody, encoding: NSUTF8StringEncoding) {
                    body = HTTPBodyString as String
                }
            }
            let response = NSString(data: responseData, encoding: NSUTF8StringEncoding) ?? "Failed to convert response data to string"
            
            let date = Plaidster.printRequestDateFormatter.stringFromDate(NSDate())
            let logMessage = "\(date) \(function):\n" +
                             "URL: \(url)\n" +
                             "Body: \(body)\n" +
                             "Response: \(response)"
            
            if let rawConnectionsLogger = rawConnectionsLogger {
                rawConnectionsLogger(item: logMessage)
            } else {
                log(logMessage)
            }
        }
    }
    
    //
    // MARK: - Public Methods -
    //
    
    public func addUser(username username: String, password: String, pin: String?, type: String, handler: AddUserHandler) {
        let URLString = "\(baseURL)connect"
        
        let optionsDictionaryString = self.dictionaryToString(["list": true])
        var parameters = "client_id=\(clientID)&secret=\(secret)&username=\(username.URLQueryParameterEncodedValue)&password=\(password.URLQueryParameterEncodedValue)&type=\(type)&options=\(optionsDictionaryString.URLQueryParameterEncodedValue)"
        if let pin = pin {
            parameters += "&pin=\(pin)"
        }
        
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        request.HTTPMethod = HTTPMethod.Post
        request.HTTPBody = parameters.dataUsingEncoding(NSUTF8StringEncoding)
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String: AnyObject] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Check for Plaidster errors
                let code = JSONResult["code"] as? Int
                let message = JSONResult["message"] as? String
                try throwPlaidsterError(code, message)
                
                // Check for an access token
                guard let token = JSONResult["access_token"] as? String else {
                    throw PlaidsterError.JSONEmpty("No access token returned")
                }
                
                // Check for an MFA response
                let MFAType = PlaidMFAType(rawValue: JSONResult["type"] as? String ?? "")
                let MFAResponse = JSONResult["mfa"] as? [[String: AnyObject]]
                if (MFAType == nil || MFAResponse == nil) && !(MFAType == nil && MFAResponse == nil) {
                    // This should never happen. It should always return both pieces of data.
                    throw PlaidsterError.JSONEmpty("Missing MFA information")
                }
                
                if let MFAType = MFAType, MFAResponse = MFAResponse {
                    // Call handler with MFA response
                    handler(accessToken: token, MFAType: MFAType, MFA: MFAResponse, accounts: nil, transactions: nil, error: maybeError)
                } else {
                    // Parse accounts if they're included
                    let unmanagedAccounts = JSONResult["accounts"] as? [[String: AnyObject]]
                    var managedAccounts: [PlaidAccount]?
                    if let unmanagedAccounts = unmanagedAccounts {
                        managedAccounts = [PlaidAccount]()
                        for result in unmanagedAccounts {
                            do {
                                let account = try PlaidAccount(account: result)
                                managedAccounts!.append(account)
                            } catch {
                                self.log(error)
                            }
                        }
                    }
                    
                    // Parse transactions if they're included
                    let unmanagedTransactions = JSONResult["transactions"] as? [[String: AnyObject]]
                    var managedTransactions: [PlaidTransaction]?
                    if let unmanagedTransactions = unmanagedTransactions {
                        managedTransactions = [PlaidTransaction]()
                        for result in unmanagedTransactions {
                            do {
                                let transaction = try PlaidTransaction(transaction: result)
                                managedTransactions!.append(transaction)
                            } catch {
                                self.log(error)
                            }
                        }
                    }
                    
                    // Call the handler
                    handler(accessToken: token, MFAType: nil, MFA: nil, accounts: managedAccounts, transactions: managedTransactions, error: maybeError)
                }
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(accessToken: nil, MFAType: nil, MFA: nil, accounts: nil, transactions: nil, error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func removeUser(accessToken: String, handler: RemoveUserHandler) {
        let URLString = "\(baseURL)connect"
        let parameters = "client_id=\(clientID)&secret=\(secret)&access_token=\(accessToken)"
        
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        request.HTTPMethod = HTTPMethod.Delete
        request.allHTTPHeaderFields = ["Content-Type": "application/x-www-form-urlencoded"]
        request.HTTPBody = parameters.dataUsingEncoding(NSUTF8StringEncoding)
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String: AnyObject] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Check for Plaidster errors
                let code = JSONResult["code"] as? Int
                let message = JSONResult["message"] as? String
                try throwPlaidsterError(code, message)
                
                // Call the handler
                handler(message: message, error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(message: nil, error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func submitMFACodeResponse(accessToken: String, code: String, handler: SubmitMFAHandler) {
        submitMFAResponse(accessToken: accessToken, responseType: .Code, response: code, handler: handler)
    }
    
    public func submitMFAQuestionResponse(accessToken: String, answer: String, handler: SubmitMFAHandler) {
        submitMFAResponse(accessToken: accessToken, responseType: .Question, response: answer, handler: handler)
    }
    
    public func submitMFADeviceType(accessToken: String, device: String, handler: SubmitMFAHandler) {
        submitMFAResponse(accessToken: accessToken, responseType: .DeviceType, response: device, handler: handler)
    }
    
    public func submitMFADeviceMask(accessToken: String, mask: String, handler: SubmitMFAHandler) {
        submitMFAResponse(accessToken: accessToken, responseType: .DeviceMask, response: mask, handler: handler)
    }
    
    public func submitMFAResponse(accessToken accessToken: String, responseType: PlaidMFAResponseType, response: String, handler: SubmitMFAHandler) {
        let URLString = "\(baseURL)connect/step"
        var parameters = "client_id=\(clientID)&secret=\(secret)&access_token=\(accessToken)"
        
        switch responseType {
        case .Code, .Question:
            parameters += "&mfa=\(response.URLQueryParameterEncodedValue)"
        case .DeviceType:
            parameters += "&options={\"send_method\":{\"type\":\"\(response)\"}}"
        case .DeviceMask:
            parameters += "&options={\"send_method\":{\"mask\":\"\(response)\"}}"
        }
        
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        request.HTTPMethod = HTTPMethod.Post
        request.HTTPBody = parameters.dataUsingEncoding(NSUTF8StringEncoding)
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String: AnyObject] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Check for Plaidster errors
                let code = JSONResult["code"] as? Int
                let message = JSONResult["message"] as? String
                try throwPlaidsterError(code, message)
                
                // Check for an MFA response
                let MFAType = PlaidMFAType(rawValue: JSONResult["type"] as? String ?? "")
                var MFAResponse = JSONResult["mfa"] as? [[String: AnyObject]]
                if MFAResponse == nil {
                    if let response = JSONResult["mfa"] as? [String: AnyObject] {
                        MFAResponse = [response]
                    }
                }
                
                if let MFAType = MFAType, MFAResponse = MFAResponse {
                    // Call handler with MFA response
                    handler(MFAType: MFAType, MFA: MFAResponse, accounts: nil, transactions: nil, error: maybeError)
                } else {
                    // Parse accounts if they're included
                    let unmanagedAccounts = JSONResult["accounts"] as? [[String: AnyObject]]
                    var managedAccounts: [PlaidAccount]?
                    if let unmanagedAccounts = unmanagedAccounts {
                        managedAccounts = [PlaidAccount]()
                        for result in unmanagedAccounts {
                            do {
                                let account = try PlaidAccount(account: result)
                                managedAccounts!.append(account)
                            } catch {
                                self.log(error)
                            }
                        }
                    }
                    
                    // Parse transactions if they're included
                    let unmanagedTransactions = JSONResult["transactions"] as? [[String: AnyObject]]
                    var managedTransactions: [PlaidTransaction]?
                    if let unmanagedTransactions = unmanagedTransactions {
                        managedTransactions = [PlaidTransaction]()
                        for result in unmanagedTransactions {
                            do {
                                let transaction = try PlaidTransaction(transaction: result)
                                managedTransactions!.append(transaction)
                            } catch {
                                self.log(error)
                            }
                        }
                    }
                    
                    // Call the handler
                    handler(MFAType: nil, MFA: nil, accounts: managedAccounts, transactions: managedTransactions, error: maybeError)
                }
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(MFAType: nil, MFA: nil, accounts: nil, transactions: nil, error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func fetchUserBalance(accessToken: String, handler: FetchUserBalanceHandler) {
        let URLString = "\(baseURL)balance?client_id=\(clientID)&secret=\(secret)&access_token=\(accessToken)"
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        
        let task = session.dataTaskWithRequest(request) { maybeData, maybeResponse, maybeError in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String: AnyObject] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Check for Plaidster errors
                let code = JSONResult["code"] as? Int
                let message = JSONResult["message"] as? String
                try throwPlaidsterError(code, message)
                
                // Check for accounts
                guard let unmanagedAccounts = JSONResult["accounts"] as? [[String: AnyObject]] else {
                    throw PlaidsterError.JSONEmpty("No accounts returned")
                }
                
                // Map the accounts and call the handler
                var managedAccounts = [PlaidAccount]()
                for result in unmanagedAccounts {
                    do {
                        let account = try PlaidAccount(account: result)
                        managedAccounts.append(account)
                    } catch {
                        self.log(error)
                    }
                }
                handler(accounts: managedAccounts, error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(accounts: [PlaidAccount](), error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func fetchUserTransactions(accessToken: String, showPending: Bool, beginDate: NSDate?, endDate: NSDate?, handler: FetchUserTransactionsHandler) {
        // Process the options dictionary. This parameter is sent as a JSON dictionary.
        var optionsDictionary: [String: AnyObject] = ["pending": true]
        if let beginDate = beginDate {
            optionsDictionary["gte"] = self.dateToJSONString(beginDate)
        }
        if let endDate = endDate {
            optionsDictionary["lte"] = self.dateToJSONString(endDate)
        }
        let optionsDictionaryString = self.dictionaryToString(optionsDictionary)
        
        // Create the URL string including the options dictionary
        let URLString = "\(baseURL)connect?client_id=\(clientID)&secret=\(secret)&access_token=\(accessToken)&options=\(optionsDictionaryString.URLQueryParameterEncodedValue)"
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String: AnyObject] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Check for Plaidster errors
                let code = JSONResult["code"] as? Int
                let message = JSONResult["message"] as? String
                try throwPlaidsterError(code, message)
                
                // Check for transactions
                guard let unmanagedTransactions = JSONResult["transactions"] as? [[String: AnyObject]] else {
                    throw PlaidsterError.JSONEmpty("No transactions returned")
                }
                
                // Map the transactions and call the handler
                var managedTransactions = [PlaidTransaction]()
                for result in unmanagedTransactions {
                    do {
                        let transaction = try PlaidTransaction(transaction: result)
                        managedTransactions.append(transaction)
                    } catch {
                        self.log(error)
                    }
                }
                handler(transactions: managedTransactions, error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(transactions: [PlaidTransaction](), error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func fetchCategories(handler: FetchCategoriesHandler) {
        let URLString = "\(baseURL)categories"
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        
        let task = session.dataTaskWithRequest(request) { maybeData, maybeResponse, maybeError in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [[String: AnyObject]] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Map the categories and call the handler
                var managedCategories = [PlaidCategory]()
                for result in JSONResult {
                    do {
                        let category = try PlaidCategory(category: result)
                        managedCategories.append(category)
                    } catch {
                        self.log(error)
                    }
                }
                
                handler(categories: managedCategories, error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(categories: [PlaidCategory](), error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func fetchInstitutions(handler: FetchInstitutionsHandler) {
        let URLString = "\(baseURL)institutions"
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [[String: AnyObject]] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Map the institutions and call the handler
                var managedInstitutions = [PlaidInstitution]()
                for result in JSONResult {
                    do {
                        let institution = try PlaidInstitution(institution: result)
                        managedInstitutions.append(institution)
                    } catch {
                        self.log(error)
                    }
                }
                handler(institutions: managedInstitutions, error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(institutions: [PlaidInstitution](), error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func fetchLongtailInstitutions(count: Int, offset: Int, handler: FetchLongtailInstitutionsHandler) {
        let URLString = "\(baseURL)institutions/longtail"
        let parameters = "client_id=\(clientID)&secret=\(secret)&count=\(count)&offset=\(offset)"
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        request.HTTPMethod = HTTPMethod.Post
        request.HTTPBody = parameters.dataUsingEncoding(NSUTF8StringEncoding)
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    throw PlaidsterError.JSONEmpty(maybeError?.localizedDescription)
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String: AnyObject], let totalCount = JSONResult["total_count"] as? Int, let results = JSONResult["results"] as? [[String: AnyObject]] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Map the instututions and call the handler
                var managedInstitutions = [PlaidInstitution]()
                for result in results {
                    do {
                        let institution = try PlaidInstitution(institution: result)
                        managedInstitutions.append(institution)
                    } catch {
                        self.log(error)
                    }
                }
                handler(institutions: managedInstitutions, totalCount: totalCount, error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(institutions: [PlaidInstitution](), totalCount: -1, error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
    }
    
    public func searchInstitutions(query query: String, product: PlaidProduct?, handler: SearchInstitutionsHandler) -> NSURLSessionDataTask {
        var URLString = "\(baseURL)institutions/search?q=\(query.URLQueryParameterEncodedValue)"
        if let product = product {
            URLString += "&p=\(product.rawValue)"
        }
       
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    // For whatever reason, this API returns empty on success when no results are returned,
                    // so in this case it's not an error. Just return an empty set.
                    handler(institutions: [PlaidSearchInstitution](), error: nil)
                    return
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [[String: AnyObject]] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Map the instututions and call the handler
                var managedInstitutions = [PlaidSearchInstitution]()
                for result in JSONResult {
                    do {
                        let institution = try PlaidSearchInstitution(institution: result)
                        managedInstitutions.append(institution)
                    } catch {
                        self.log(error)
                    }
                }
                handler(institutions: managedInstitutions, error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(institutions: [PlaidSearchInstitution](), error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
        
        return task
    }
    
    public func searchInstitutions(id id: String, handler: SearchInstitutionsHandler) -> NSURLSessionDataTask {
        let URLString = "\(baseURL)institutions/search?id=\(id)"
        let URL = NSURL(string: URLString)!
        let request = NSMutableURLRequest(URL: URL)
        request.timeoutInterval = connectionTimeout
        
        let task = session.dataTaskWithRequest(request) { (maybeData, maybeResponse, maybeError) in
            do {
                // Make sure there's data
                guard let data = maybeData where maybeError == nil else {
                    // For whatever reason, this API returns empty on success when no results are returned,
                    // so in this case it's not an error. Just return an empty set.
                    handler(institutions: [PlaidSearchInstitution](), error: nil)
                    return
                }
                
                // Print raw connection if option enabled
                self.printRequest(request, responseData: data)
                
                // Try to parse the JSON
                guard let JSONResult = try NSJSONSerialization.JSONObjectWithData(data, options: .MutableContainers) as? [String: AnyObject] else {
                    throw PlaidsterError.JSONDecodingFailed
                }
                
                // Map the institution and call the handler
                let managedInstitution = try PlaidSearchInstitution(institution: JSONResult)
                handler(institutions: [managedInstitution], error: maybeError)
            } catch {
                // Convert exceptions into NSErrors for the handler
                handler(institutions: [PlaidSearchInstitution](), error: cocoaErrorFromException(error))
            }
        }
        
        task.resume()
        
        return task
    }
}