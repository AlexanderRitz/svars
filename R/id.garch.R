#' GARCH identification of SVAR models
#'
#' Given an estimated VAR model, this function applies changes in volatility to identify the structural impact matrix B of the corresponding SVAR model
#' \deqn{y_t=c_t+A_1 y_{t-1}+...+A_p y_{t-p}+u_t
#' =c_t+A_1 y_{t-1}+...+A_p y_{t-p}+B \epsilon_t.}
#' Matrix B corresponds to the decomposition of the pre-break covariance matrix \eqn{\Sigma_1=B B'}.
#' The post-break covariance corresponds to \eqn{\Sigma_2=B\Lambda B'} where \eqn{\Lambda} is the estimated unconditional heteroskedasticity matrix.
#'
#' @param x An object of class 'vars', 'vec2var', 'nlVar'. Estimated VAR object
#' @param SB Integer, vector or date character. The structural break is specified either by an integer (number of observations in the pre-break period),
#'                    a vector of ts() frequencies if a ts object is used in the VAR or a date character. If a date character is provided, either a date vector containing the whole time line
#'                    in the corresponding format (see examples) or common time parameters need to be provided
#' @param dateVector Vector. Vector of time periods containing SB in corresponding format
#' @param start Character. Start of the time series (only if dateVector is empty)
#' @param end Character. End of the time series (only if dateVector is empty)
#' @param frequency Character. Frequency of the time series (only if dateVector is empty)
#' @param format Character. Date format (only if dateVector is empty)
#' @param restriction_matrix Matrix. A matrix containing presupposed entries for matrix B, NA if no restriction is imposed (entries to be estimated)
#' @param max.iter Integer. Number of maximum GLS iterations
#' @param crit Integer. Critical value for the precision of the GLS estimation
#' @return A list of class "svars" with elements
#' \item{Lambda}{Estimated unconditional heteroscedasticity matrix \eqn{\Lambda}}
#' \item{Lambda_SE}{Matrix of standard errors of Lambda}
#' \item{B}{Estimated structural impact matrix B, i.e. unique decomposition of the covariance matrix of reduced form residuals}
#' \item{B_SE}{Standard errors of matrix B}
#' \item{n}{Number of observations}
#' \item{Fish}{Observed Fisher information matrix}
#' \item{Lik}{Function value of likelihood}
#' \item{wald_statistic}{Results of pairwise Wald tests}
#' \item{iteration}{Number of GLS estimations}
#' \item{method}{Method applied for identification}
#' \item{SB}{Structural break (number of observations)}
#' \item{A_hat}{Estimated VAR paramter via GLS}
#' \item{type}{Type of the VAR model, e.g. 'const'}
#' \item{SBcharacter}{Structural break (date; if provided in function arguments)}
#' \item{restrictions}{Number of specified restrictions}
#' \item{restriction_matrix}{Specified restriction matrix}
#' \item{y}{Data matrix}
#' \item{p}{Number of lags}
#' \item{K}{Dimension of the VAR}
#'
#' @references Rigobon, R., 2003. Identification through Heteroskedasticity. The Review of Economics and Statistics, 85, 777-792.\cr
#'  Herwartz, H. & Ploedt, M., 2016. Simulation Evidence on Theory-based and Statistical Identification under Volatility Breaks Oxford Bulletin of Economics and Statistics, 78, 94-112.
#'
#' @seealso For alternative identification approaches see \code{\link{id.st}}, \code{\link{id.cvm}}, \code{\link{id.dc}} or \code{\link{id.ngml}}
#'
#' @examples
#' \donttest{
#' # data contains quartlery observations from 1965Q1 to 2008Q2
#' # assumed structural break in 1979Q3
#' # x = output gap
#' # pi = inflation
#' # i = interest rates
#' set.seed(23211)
#' v1 <- vars::VAR(USA, lag.max = 10, ic = "AIC" )
#' x1 <- id.cv(v1, SB = 59)
#' summary(x1)
#'
#' # switching columns according to sign patter
#' x1$B <- x1$B[,c(3,2,1)]
#' x1$B[,3] <- x1$B[,3]*(-1)
#'
#' # Impulse response analysis
#' i1 <- irf(x1, n.ahead = 30)
#' plot(i1, scales = 'free_y')
#'
#' # Restrictions
#' # Assuming that the interest rate doesn't influence the output gap on impact
#' restMat <- matrix(rep(NA, 9), ncol = 3)
#' restMat[1,3] <- 0
#' x2 <- id.cv(v1, SB = 59, restriction_matrix = restMat)
#' summary(x2)
#'
#' #Structural brake via Dates
#' # given that time series vector with dates is available
#' dateVector = seq(as.Date("1965/1/1"), as.Date("2008/7/1"), "quarter")
#' x3 <- id.cv(v1, SB = "1979-07-01", format = "%Y-%m-%d", dateVector = dateVector)
#' summary(x3)
#'
#' # or pass sequence arguments directly
#' x4 <- id.cv(v1, SB = "1979-07-01", format = "%Y-%m-%d", start = "1965-01-01", end = "2008-07-01",
#' frequency = "quarter")
#' summary(x4)
#'
#' # or provide ts date format (For quarterly, monthly, weekly and daily frequencies only)
#' x5 <- id.cv(v1, SB = c(1979, 3))
#' summary(x5)
#'
#' }
#' @importFrom steadyICA steadyICA
#' @export


#----------------------------#
## Identification via GARCH ##
#----------------------------#

# x  : object of class VAR
# SB : structural break


id.garch <- function(x, max.iter = 50, crit = 0.001, restriction_matrix = NULL){

  u <- Tob <- p <- k <- residY <- coef_x <- yOut <- type <- y <-  NULL
  get_var_objects(x)

  sigg <- crossprod(u)/(Tob-1-k*p)

  # Polar decomposition as in Lanne Saikkonen
  eigVectors <- eigen(sigg)$vectors
  eigVectors <- eigVectors[,rev(1:ncol(eigVectors))]
  eigValues <- diag(rev(eigen(sigg)$values))
  eigVectors[,2] <- eigVectors[,2]*(-1)

  CC <- eigVectors %*% sqrt(eigValues) %*% t(eigVectors)
  B0 <- solve(solve(sqrt(eigValues)) %*% t(eigVectors))

  #B_0 <- sqrtm(sigg)

  # Initial structural erros
  #ste <- B_0 %*% t(u)
  ste <- solve(sqrt(eigValues)) %*% t(eigVectors) %*% t(u)

  ## Stage 1: Univariate optimization of GARCH(1, 1) parameter
  # Initial values as in Lütkepohl + Schlaak (2018)
  init_gamma <- runif(5)
  init_g <- rep(NA, k)
  test_g <- NA
  for(i in 1:k){
    test_g <- runif(1)
    if(init_gamma[i] + test_g < 1){
      init_g[i] <- test_g
    }else{
      while(init_gamma[i] + test_g > 1){
        test_g <- runif(1)
        if(init_gamma[i] + test_g < 1){
          init_g[i] <- test_g
        }
      }
    }
  }
  init_gamma <- rep(0.01, 5)
  init_g <- rep(0.83261, 5)

  Sigma_e_0 <-  matrix(1, Tob-p, k)
  # first observstion of strucutral variance is the estimated sample variance
  Sigma_e_0 <-  matrix(diag(var(t(ste)))[1],  Tob-p, k)
  Sigma_e_0 <-  matrix(1,  Tob-p, k)

  parameter_ini_univ <- cbind(init_gamma, init_g)

  # optimizing the univariate likelihood functions
  maxL <- list()
  gamma_univ <- rep(NA, k)
  g_univ <- rep(NA, k)
  param_univ <- matrix(NA, 3, k)
  Sigma_e_univ <- matrix(NA, Tob-p, k)

  for(i in 1:k){
    maxL <- nlm(p = parameter_ini_univ[i, ], f = likelihood_garch_uni, k = k, Tob = Tob,
                Sigma_1 = Sigma_e_0[, i] , est = ste[i, ], lags = p)

    gamma_univ[i] <- maxL$estimate[1]
    g_univ[i] <- maxL$estimate[2]

    param_univ[, i] <- rbind((1- gamma_univ[i]- g_univ[i]), gamma_univ[i], g_univ[i])
    Sigma_e_univ[,i] <- sigma_garch_univ(param_univ[,i], Tob, k, Sigma_e_0[,i], ste[i,], p)
  }

  # Multivariate optimization
  # INITIAL VALUES: construct B, i.e. insert 1 on main diagonal, only K^2-K parameters need to be estiated
  # normalize the inverse of B to have ones on main diagonal
  B_0_inv <- solve(B0)
  norm_inv <- solve(diag(diag(B_0_inv), k, k))
  B_0_inv_norm <-  norm_inv%*%B_0_inv
  B_0_norm <- solve(norm_inv%*%B_0_inv)

  B_param_ini <- B_0_norm[col(B_0_norm) != row(B_0_norm)]
  diag_elements <- 1/(diag(B_0_inv))

  ini <- c(B_param_ini, diag_elements)

  # create empty vectors that hold the estimated parameters and paste initial values
  gamma <- rep(NA, k)
  g <-  rep(NA, k)
  # const <- vector(mode="numeric", length = spec$gcomp)
  const <- const_ini
  param <-  param_univ
  results_B <- vector(mode = "list")
  results_param <- vector(mode = "list")
  round <-  1
  SSR <- matrix(NA, 1, 2)
  SSR_help <-  matrix(NA, 1,2)
  SSR[,1:2] <- c(1,1)
  while (SSR[round,2] > 10^-4){
    max_ml <- nlm(ini, f = garch_ll_first_Binv, k = k, Tob = Tob,
                  Sigma_e = Sigma_e_univ , u = u, lags = p)
    max_ml$minimum
    # initials for next round of estimation
    ini <- max_ml$estimate
    # get the B matrix from the estimated parameters
    B_inv[col(B_inv) != row(B_inv)] <- ini[1:(k^2-k)]
    B <- solve(B_inv)

    diagonal_mat <- diag(ini[(k^2-k+1):k^2])

    B_est <- B%*%diagonal_mat
    B_est_inv <- solve(B_est)
    # save individual B matrices for each round
    results_B[[round]] <- B
    # calculate new structural residuals for update of the GARCH parameters
    est_r <- solve(B_est) %*% t(u)

    # calculate the new "starting value" for the variance of structural error
    SSR_help[1,1] <- max_ml$minimum
    SSR_help[1,2] <- abs((SSR_help[1,1] - SSR[round,1] ) / SSR[round,1]);
    SSR <- rbind(SSR, SSR_help)

    # re-estimate GARCH part, based on update of estimate of B
    # optimizing the univariate likelihood functions
    maxL <- list()
    gamma_univ <- rep(NA, k)
    g_univ <- rep(NA, k)
    param_univ <- matrix(NA, 3, k)
    Sigma_e_univ <- matrix(NA, Tob-p, k)

    for(i in 1:k){
      maxL <- nlm(p = parameter_ini_univ[i, ], f = likelihood_garch_uni, k = k, Tob = Tob,
                  Sigma_1 = Sigma_e_0[, i] , est = est_r[i, ], lags = p)

      gamma_univ[i] <- maxL$estimate[1]
      g_univ[i] <- maxL$estimate[2]

      param_univ[, i] <- rbind((1- gamma_univ[i]- g_univ[i]), gamma_univ[i], g_univ[i])
      Sigma_e_univ[,i] <- sigma_garch_univ(param_univ[,i], Tob, k, Sigma_e_0[,i], ste[i,], p)
    }

    results_param[[round]] <- param_univ
    cat("Round of algorithm is ", round,". LL:", SSR_help[1,1],  ". LL-change: ", SSR_help[1,2], ".\n")
    round <-  round + 1
  } # end of while loop


}