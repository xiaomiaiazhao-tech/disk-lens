import Foundation
do {try selfTest()} catch {fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)}
