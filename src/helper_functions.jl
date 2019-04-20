# #----------------------------------------------------------------------------------------------------------------------
# #----------------------------------------------------------------------------------------------------------------------
# This file contains functions and other snippets of code that are used in various calculations for creating, 
# optimizing, and evaluating the results of RICE+AIR.
# #----------------------------------------------------------------------------------------------------------------------
# #----------------------------------------------------------------------------------------------------------------------

########################################################################################################################
# CUSTOM INPUT TYPE TO RUN RICE+AIR 
########################################################################################################################
# Description: This creates a custom type to store the user-defined inputs to run an instance of RICE+AIR.  The 
#              "RICE_AIR_input" type will be created for each separate optimization of RICE+AIR, with the model 
#               settings dependent on the parameters supplied in the "user_interface.jl" file.  Descriptions of 
#               each input parameter can be found in the "user_interface.jl" file.
#----------------------------------------------------------------------------------------------------------------------

struct RICE_AIR_inputs
    nsteps::Int64
    rho::Float64
    eta::Float64
    tau::Float64
    kuznets_term::Float64
    SSP_scenario::Symbol
    Hyears::Float64
    use_VSL::Bool
    VOLY_elasticity::Float64
end

########################################################################################################################
# LOAD MODEL PARAMETERS FROM RICE 2010
########################################################################################################################
# Description: This functions extracts model parameters from the unmodified Mimi version of RICE that are needed to 
#              construct the RICE+AIR model (Note: you must call "using MimiRICE2010" once before using this function).
#----------------------------------------------------------------------------------------------------------------------

function load_rice_parameters()

    # Load and run an instance of RICE 2010.
    rice2010 = getrice()
    run(rice2010)

    # Extract and return the necessary parameters.
    p = Dict{Symbol,Any}()

    p[:population] = rice2010[:grosseconomy, :l]

    p[:mat0] = rice2010[:co2cycle, :mat0]
    p[:mat1] = rice2010[:co2cycle, :mat1]
    p[:mu0]  = rice2010[:co2cycle, :mu0]
    p[:ml0]  = rice2010[:co2cycle, :ml0]
    p[:b12]  = rice2010[:co2cycle, :b12]
    p[:b23]  = rice2010[:co2cycle, :b23]
    p[:b11]  = rice2010[:co2cycle, :b11]
    p[:b21]  = rice2010[:co2cycle, :b21]
    p[:b22]  = rice2010[:co2cycle, :b22]
    p[:b32]  = rice2010[:co2cycle, :b32]
    p[:b33]  = rice2010[:co2cycle, :b33]

    p[:fco22x]  = rice2010[:climatedynamics, :fco22x]
    p[:t2xco2]  = rice2010[:climatedynamics, :t2xco2]
    p[:tatm0]   = rice2010[:climatedynamics, :tatm0]
    p[:tocean0] = rice2010[:climatedynamics, :tocean0]
    p[:c1]      = rice2010[:climatedynamics, :c1]
    p[:c3]      = rice2010[:climatedynamics, :c3]
    p[:c4]      = rice2010[:climatedynamics, :c4]

    return p
end


#######################################################################################################################
# CALCULATE REGIONAL CO₂ MITIGATION
########################################################################################################################
# Description: This function calculates regional CO₂ mitigation levels as a function of a global carbon tax.  It
#              uses the RICE2010 backstop price values and assumes a carbon tax of $0 in period 1.  If the number of
#              tax values is less than the total number of model time periods, the function assumes full decarbonization
#              (e.g. the tax = the backstop price) for all future periods without a specified tax.
#
# Function Arguments:
#                      
#       tax:            A vector of global carbon tax values to be optimized.
#       backstop_price: The regional backstop prices from RICE2010.
#       theta2:         The exponent on the abatement cost function (defaults to RICE2010 value).
#----------------------------------------------------------------------------------------------------------------------

function mu_from_tax(tax::Array{Float64,1}, backstop_price::Array{Float64,2}, theta2::Float64)
    backstop = backstop_price .* 1000.0
    pbmax = maximum(backstop, dims=2)
    # Set all tax values to maximum of the backstop price across all regions.
    TAX = [0.0; pbmax[2:end]]
    # Set the periods being optimized to the suppled tax value (assume full decarbonization for other periods).
    TAX[2:(length(tax)+1)] = tax
    # Calculate regional mitigation rates from the tax vector.
    mu = min.((max.(((TAX ./ backstop) .^ (1 / (theta2 - 1.0))), 0.0)), 1.0)

    return mu, TAX
end


#######################################################################################################################
# CREATE RICE+AIR OBJECTIVE FUNCTION
########################################################################################################################
# Description: This function creates an objective function that incorporates an instance of RICE+AIR with user-specified
#              parameter settings.  The objective function will take in a vector of global carbon tax values and returns
#              the total economic welfare generated by that specifc climate policy.  The function assumes that once the
#              carbon tax hits the backstop price (full decarbonization), it stays there.
#
# Function Arguments:
#                      
#       inputs:          User-defined settings for RICE+AIR (the custom RICE_AIR_inputs type).
#       backstop_prices  The regional backstop prices from RICE2010.
#       cobenefits:      A true/false statement to decide if co-beneifts are accounted for (true = account for co-benefits).
#----------------------------------------------------------------------------------------------------------------------

function construct_rice_air_objective(inputs::RICE_AIR_inputs, backstop_price::Array{Float64,2}, cobenefits::Bool)

    # Get an instance of RICE-AIR, given user parameter specifications.
    m = construct_rice_air(inputs)

    # If optimizing reference case, set health co-benefits to 0.
    if cobenefits == false
        set_param!(m, :air_consumption, :lifeyears, zeros(inputs.nsteps, 12))
        set_param!(m, :air_consumption, :avoided_deaths, zeros(inputs.nsteps, 12))
    end

    # Create a function to optimize given user settings (function takes a tax vector and returns total welfare from RICE+AIR).
    function rice_air_objective(opt_tax::Array{Float64,1})

        # Check to see if carbon tax hits the backstop price, but does not remain there (e.g. optimization noise in late periods).
        equality_check = round.(opt_tax, digits=2) .== round.(maximum(backstop_price .* 1000,dims=2), digits=2)[2:(length(opt_tax)+1)]

        # Set any noise values that violate backstop price assumption to the backstop price.
        if any(equality_check)
            true_index = findall(equality_check)[1]
            # Set all noise values after hitting backstop to the backstop price.
            opt_tax[true_index:end] = maximum(backstop_price[2:end,:] .* 1000, dims=2)[true_index:length(opt_tax)]
        end

        # Calculate regional CO₂ mitigation levels from the carbon tax vector, run RICE+AIR with this policy, and return welfare.
        abatement_level, tax = mu_from_tax(opt_tax, backstop_price, 2.8)
        set_param!(m, :emissions, :MIU, abatement_level)
        set_param!(m, :air_coreduction, :MIU, abatement_level)
        run(m)
        return m[:welfare, :welfare]
    end
    
    # Return the newly created objective function.
    return rice_air_objective, m
end


#######################################################################################################################
# OPTIMIZE RICE+AIR
########################################################################################################################
# Description: This function takes an objective function (given user-supplied model settings), and optimizes it by 
#              finding the global carbon tax that maximizes economic welfare.  The function returns the optimal
#              regional CO₂ mitigation levels, optimal carbon tax, an instance of RICE+AIR, and the policy vector
#              for all periods being optimized.
#
# Function Arguments:
#                      
#       inputs:          User-defined settings for RICE+AIR (the custom RICE_AIR_inputs type).
#       algorithm:       The optimization algorithm to use from the NLopt package.
#       n_objectives:    The number of ten-year model time periods to optimize over (max = 60).
#       stop_time:       The length of time (in seconds) for the optimization to run in case things do not converge.
#       tolerance:       Relative tolerance criteria for convergence (will stop if |Δf| / |f| < tolerance from one iteration to the next.)
#       backstop_price:  The regional backstop prices from RICE2010.
#       cobenefits:      A true/false statement to decide if co-beneifts are accounted for (true = account for co-benefits).
#       starting_point:  Vector of carbon taxes to initialize the optimization.
#----------------------------------------------------------------------------------------------------------------------

function optimize_rice_air(inputs::RICE_AIR_inputs, algorithm::Symbol, n_objectives::Int64, stop_time::Int64, tolerance::Float64, backstop_price::Array{Float64,2}, cobenefits::Bool, starting_point)

    # Create objective function, given user settings.
    objective_function, opt_m = construct_rice_air_objective(inputs, backstop_price, cobenefits)

    #Extract RICE backstop price values and index/scale for RICE (used to set upperbound).
    upperbound = maximum(rice_parameters[:pbacktime], dims=2)[2:(n_objectives+1)].*1000.0

    opt = Opt(algorithm, n_objectives)

    lower_bounds!(opt, zeros(n_objectives))
    upper_bounds!(opt, upperbound)

    max_objective!(opt, (x, grad) -> objective_function(x))

    maxtime!(opt, stop_time)
    ftol_rel!(opt, tolerance)

    (minf,minx,ret) = optimize(opt, starting_point)
    println("Convergence result: ", ret)

    # Carry out final check for noise after hitting backstop price.
    equality_check = round.(minx, digits=2) .== round.(maximum(backstop_price .* 1000, dims=2), digits=2)[2:(length(minx)+1)]

    if any(equality_check)
        true_index = findall(equality_check)[1]
        # Set all noise values after hitting backstop to the backstop price
        minx[true_index:end] = maximum(backstop_price[2:end,:] .* 1000, dims=2)[true_index:length(minx)]
    end

    # Get matrix of regional MIU values from optimal tax.
    opt_abatement_level, tax = mu_from_tax(minx, backstop_price, 2.8)

    return opt_abatement_level, tax, opt_m, minx
end


#######################################################################################################################
# CALCULATE GLOBAL CO₂ MITIGATION LEVELS
#######################################################################################################################
# Description: This function takes an optimized version of RICE+AIR and returns the global reduction in CO₂ emissions
#              relative to a baseline case without a climate policy.
#
# Function Arguments:
#                      
#       opt_m: An optimized vversion of RICE+AIR (type = Mimi.Model).
#----------------------------------------------------------------------------------------------------------------------

function global_mitigation_mix(opt_m::Mimi.Model)

    # Get baseline version of RICE+AIR without CO₂ mitigation policy.
    global_emissions_opt  = sum(opt_m[:emissions, :EIND], dims=2)
    base_m = deepcopy(opt_m)
    set_param!(base_m, :emissions, :MIU, zeros(inputs.nsteps, 12))
    set_param!(base_m, :air_coreduction, :MIU, zeros(inputs.nsteps, 12))
    run(base_m)

    global_emissions_base = sum(base_m[:emissions, :EIND], dims=2)

    # Calculate change in global CO₂ mitiation levels.
    global_mitigation_rates = ((global_emissions_base .- global_emissions_opt) ./ global_emissions_base)
    return global_mitigation_rates
end


#######################################################################################################################
# LOAD RICE+AIR DATA AND FIXED PARAMETERS
#######################################################################################################################
# Description: This function loads and cleans up the RICE+AIR data so it can be incorporated into the model.
#
# Function Arguments:
#                      
#       SSP_scenario: A symbol indicating which SSP scneario should be used to calculate the co-reduction relationship.
#----------------------------------------------------------------------------------------------------------------------
function load_air_parameters(SSP_scenario::Symbol)

    #Create dictionary to hold cleaned up parameter values and data.
    p = Dict{Symbol,Any}()

    # Open data file and extract releveant sheets.
    f = "data/RICE_AIR_Parameters.xlsx"
    phi_omega_data = DataFrame(load(f, "phi Omega!A1:G61"))
    kappa_data = DataFrame(load(f, "kappa!A1:I61"))
    u1_u0_data = DataFrame(load(f, "u1 u0!A1:E49"))
    SR_data = DataFrame(load(f, "SR!A1:E37"))
    exog_rf_data = DataFrame(load(f, "fex!A1:Q10"))
    theta_data = DataFrame(load(f, "Theta!B1:AD13"))
    death_data = DataFrame(load(f, "Deaths!B1:AD13"))
    population_data = DataFrame(load(f, "Population!C1:AE13"))

    # Specify region names from RICE2010.
    regions = ["US", "EU", "Japan", "Russia", "Eurasia", "China", "India", "MidEast", "Africa", "LatAm", "OHI", "OthAs"]

   #-------------------------------------------------------------
    # POPULATION TERMS
   #-------------------------------------------------------------
    population = zeros(60,12)
    #Number of periods with data.
    for t in 1:29
        for r in 1:length(regions)
            population[t,r] = population_data[r,t]
        end
    end
    #Set all subsequent periods to last period with data.
    for t in 30:60
        population[t,:] .= population[29,:]
    end
    p[:population] = population

   #-------------------------------------------------------------
    # PHI AND OMEGA TERMS
   #-------------------------------------------------------------
    pollutants = ["SO2", "PM_2_5", "NOX", "PM_BC", "PM_OC"]

    phi1 = zeros(length(regions), 5)
    for (y,poll) in enumerate(pollutants)
        for (x,reg) in enumerate(regions)
            # Isolate pollutant.
            aerosol = phi_omega_data[findall(z-> z==poll, phi_omega_data[:POLL]),:]
            # Reorder regions for that pollutant.
            phi1[x,y] = aerosol[findall(z-> z==reg, aerosol[:Region]), :phi1][1]
        end
    end

    phi2 = zeros(length(regions), 5)
    for (y,poll) in enumerate(pollutants)
        for (x,reg) in enumerate(regions)
            # Isolate pollutant.
            aerosol = phi_omega_data[findall(z-> z==poll, phi_omega_data[:POLL]),:]
            # Reorder regions for that pollutant.
            phi2[x,y] = aerosol[findall(z-> z==reg, aerosol[:Region]), :phi2][1]
        end
    end

    phi3 = zeros(length(regions), 5)
    for (y,poll) in enumerate(pollutants)
        for (x,reg) in enumerate(regions)
            # Isolate pollutant.
            aerosol = phi_omega_data[findall(z-> z==poll, phi_omega_data[:POLL]),:]
            # Reorder regions for that pollutant.
            phi3[x,y] = aerosol[findall(z-> z==reg, aerosol[:Region]), :ph3][1]
        end
    end

    omega1 = zeros(length(regions), 5)
    for (y,poll) in enumerate(pollutants)
        for (x,reg) in enumerate(regions)
            # Isolate pollutant.
            aerosol = phi_omega_data[findall(z-> z==poll, phi_omega_data[:POLL]),:]
            # Reorder regions for that pollutant.
            omega1[x,y] = aerosol[findall(z-> z==reg, aerosol[:Region]), :Omega1][1]
        end
    end

    omega2 = zeros(length(regions), 5)
    for (y,poll) in enumerate(pollutants)
        for (x,reg) in enumerate(regions)
            # Isolate pollutant.
            aerosol = phi_omega_data[findall(z-> z==poll, phi_omega_data[:POLL]),:]
            # Reorder regions for that pollutant.
            omega2[x,y] = aerosol[findall(z-> z==reg, aerosol[:Region]), :Omega2][1]
        end
    end

    p[:phi_1]   = phi1
    p[:phi_2]   = phi2
    p[:phi_3]   = phi3
    p[:omega_1] = omega1
    p[:omega_2] = omega2

   #-------------------------------------------------------------
   # Innitial Pollution and Exposure Levels
   #-------------------------------------------------------------
    p[:SO2₀]  = vec(Array(readxl(f, "E_2005!B3:M3")))
    p[:PM25₀] = vec(Array(readxl(f, "E_2005!B2:M2")))
    p[:NOX₀]  = vec(Array(readxl(f, "E_2005!B4:M4")))
    p[:exposure_2005] = vec(Array(readxl(f, "C_2005!A2:L2")))

   #-------------------------------------------------------------
   # β
   #-------------------------------------------------------------

    p[:β] = readxl(f, "beta!A1:A1")

   #-------------------------------------------------------------
   # Kappa
   #-------------------------------------------------------------

    pollutants = ["SO2", "PM2.5", "NOx", "BC", "OC"]
    kappa = zeros(length(regions), 5)
    for (y,poll) in enumerate(pollutants)
        for (x,reg) in enumerate(regions)
            # Isolate pollutant.
            aerosol = kappa_data[findall(z-> z==poll, kappa_data[:Pollutant]),:]
            # Reorder regions for that pollutant.
            kappa[x,y] = aerosol[findall(z-> z==reg, aerosol[:Region]), SSP_scenario][1]
        end
    end

    p[:kappa]  = kappa

   #-------------------------------------------------------------
   # Source Receptor Matrix
   #-------------------------------------------------------------
    SR_SO2 = zeros(12)
    SR_PM25 = zeros(12)
    SR_NOX = zeros(12)

    for (x,reg) in enumerate(regions)
        # Isolate pollutant.
        aerosol = SR_data[findall(z-> z=="SO2", SR_data[:p]),:]
        SR_SO2[x] = aerosol[findall(z-> z==reg, aerosol[:i]), Symbol("SR_ii'p")][1]

        aerosol = SR_data[findall(z-> z=="PM_2_5", SR_data[:p]),:]
        SR_PM25[x] = aerosol[findall(z-> z==reg, aerosol[:i]), Symbol("SR_ii'p")][1]

        aerosol = SR_data[findall(z-> z=="NOX", SR_data[:p]),:]
        SR_NOX[x] = aerosol[findall(z-> z==reg, aerosol[:i]), Symbol("SR_ii'p")][1]
    end

    p[:sr_SO2]  = SR_SO2
    p[:sr_PM25] = SR_PM25
    p[:sr_NOX]  = SR_NOX

   #-------------------------------------------------------------
   # Θ
   #-------------------------------------------------------------
    Θ = zeros(60,12)
    #Number of periods with data
    for t in 1:29
        for r in 1:length(regions)
            Θ[t,r] = theta_data[r,t]
        end
    end
    #Set all subsequent periods to last period with data.
    for t in 30:60
        Θ[t,:] .= Θ[29,:]
    end

    p[:Θ] = Θ

   #-------------------------------------------------------------
   # Deaths
   #-------------------------------------------------------------
    base_deaths = zeros(60,12)
    #Number of periods with data
    for t in 1:29
        for r in 1:length(regions)
            base_deaths[t,r] = death_data[r,t]
        end
    end
    #Set all subsequent periods to last period with data.
    for t in 30:60
        base_deaths[t,:] .= base_deaths[29,:]
    end

    p[:base_deaths] = base_deaths

   #-------------------------------------------------------------
   # u1 and u0 terms
   #-------------------------------------------------------------

    u1_SO2 = zeros(12)
    u0_SO2 = zeros(12)
    u1_NOX = zeros(12)
    u0_NOX = zeros(12)
    u1_BC = zeros(12)
    u0_BC = zeros(12)
    u1_OC = zeros(12)
    u0_OC = zeros(12)

    for (x,reg) in enumerate(regions)
       # Isolate pollutant.
       aerosol = u1_u0_data[findall(z-> z=="SO2", u1_u0_data[:POLL]),:]
       u1_SO2[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u1][1]
       u0_SO2[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u0][1]

       aerosol = u1_u0_data[findall(z-> z=="NOX", u1_u0_data[:POLL]),:]
       u1_NOX[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u1][1]
       u0_NOX[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u0][1]

       aerosol = u1_u0_data[findall(z-> z=="PM_BC", u1_u0_data[:POLL]),:]
       u1_BC[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u1][1]
       u0_BC[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u0][1]

       aerosol = u1_u0_data[findall(z-> z=="PM_OC", u1_u0_data[:POLL]),:]
       u1_OC[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u1][1]
       u0_OC[x] = aerosol[findall(z-> z==reg, aerosol[:Region]), :u0][1]
    end

   p[:u0_SO2] = u0_SO2
   p[:u0_NOX] =u0_NOX
   p[:u0_BC] = u0_BC
   p[:u0_OC] = u0_OC

   p[:u1_SO2] = u1_SO2
   p[:u1_NOX] = u1_NOX
   p[:u1_BC] = u1_BC
   p[:u1_OC] = u1_OC

   #-------------------------------------------------------------
   # Exogenous Radiative Forcing
   #-------------------------------------------------------------

   exog_rf = zeros(60)
   #Read in data and sum columns.
   for t in 1:15
       exog_rf[t] = sum(exog_rf_data[:,(t+2)])
   end

   #Hold all subsequent periods constant to Period 15 value
   exog_rf[16:end] .= exog_rf[15]

   p[:total_exogeous_rf] = exog_rf

   # Return cleaned up RICE+AIR parameters and data.
   return p
end
