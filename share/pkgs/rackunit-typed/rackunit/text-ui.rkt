#lang typed/racket
(require typed/rackunit)

(define-type Verbosity
  (U 'quiet 'normal 'verbose))

(require/typed/provide
 rackunit/text-ui
 [run-tests
  (case-lambda
    (Test -> Natural)
    (Test Verbosity -> Natural))])
(provide Verbosity)
