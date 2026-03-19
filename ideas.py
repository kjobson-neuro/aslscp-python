# Notes/ideas for ASL processing script #



# Suggested to create a new folder within share, i think this is a good idea to keep data clean, and could remove everything in that directory and not worry about deleting someone else's data
ASL_SHARE_FOLDER = '/tmp/share/asl_data'
M0_FILE = ASL_SHARE_FOLDER + '/m0.h5'

def process_image(imgGroup, connection, config, mrdHeader):
    # create folder if it doesn't exist
    os.makedirs(ASL_SHARE_FOLDER, exist_ok=True)
    
    if isM0(mrdHeader): # need to define this function somehow
    # server already saved it via -s flag, just copy it to your persistent location
        with ismrmrd.Dataset(M0_FILE, connection.savedataGroup) as dset: # if that connection thing doesn't work we can just put a string
            dset.write_xml_header(mrdHeader)
            for img in imgGroup:
                dset.append_image('images', img)
        return []
    
    if os.path.exists(M0_FILE):
        # load M0 data
        with ismrmrd.Dataset(M0_FILE, 'dataset', False) as dset:
            m0Header = ismrmrd.xsd.CreateFromDocument(dset.read_xml_header())
            for imgNum in range(0, dset.number_of_images(group)):
                m0Images = dset.read_image(group, imgNum)
        # closes automatically here
        
        # reconstruct perfusion map
        perfusionMap = reconstructASL(m0Images, m0Header, imgGroup, mrdHeader) #our code
        
        # clean up M0 file
        os.remove(M0_FILE) #double check this
        logging.info("M0 file cleaned up after reconstruction")
        
        return perfusionMap
    
    else:
        logging.warning("ASL received but no M0 found in %s", M0_FILE)
        return []
    



def reconstructASL(imgGroup, mrdHeader, m0Images, m0Header ):
    aslImages = imgGroup
    # get these numbers from the headers, hopefully: LD, PLD, NBS, M0_SCALE
    logging.info("Extracting acquisition parameters")
    
    if LD is not None and PLD is not None and NBS is not None and M0_SCALE is not None:

        logging.info("Sequence parameters found")
        
    else: 
        logging.warning("Sequence parameters not found")

    preProcessedASL, preProcessedm0, mask = preProcessASL(aslImages, m0Images)
    subtractionImg = run_asl_subtration(preProcessedASL,preProcessedm0)
    perfusionMap = cbf_calc(preProcessedASL, preProcessedm0, mask, LD, PLD, NBS, M0_SCALE ) #existing python function, modify inputs
    return perfusionMap


def preProcessASL(aslImages, m0Images):
    # Motion Correction
    logging.info("Running motion correction")
    preProcessedASL=[] # placeholder for VS code
    preProcessedm0=[]
    # Merge data 
    # MoCo
    # Split data back up after moco

    # Skull stripping
    logging.info("Performing skull stripping")

    return preProcessedASL, preProcessedm0, mask


def run_asl_subtration(preProcessedASL,preProcessedm0):
    subtractionImg = preProcessedASL-preProcessedm0 # whatever this is supposed to be 
    return subtractionImg
